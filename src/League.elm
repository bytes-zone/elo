module League exposing
    ( League, init, decoder, encode
    , addPlayer, players, getPlayer, retirePlayer
    , Match(..), currentMatch, nextMatch, startMatch, Outcome(..), finishMatch, kFactor
    )

{-|

@docs League, init, decoder, encode

@docs addPlayer, players, getPlayer, retirePlayer

@docs Match, currentMatch, nextMatch, startMatch, Outcome, finishMatch, kFactor

-}

import Dict as ComparableDict
import Elo
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Player exposing (Player, PlayerId)
import Random exposing (Generator)
import Sort.Dict as Dict exposing (Dict)


type League
    = League
        { players : Dict PlayerId Player
        , currentMatch : Maybe Match
        }


type Match
    = Match Player Player



-- LOADING AND SAVING


init : League
init =
    League
        { players = Dict.empty Player.idSorter
        , currentMatch = Nothing
        }


decoder : Decoder League
decoder =
    Decode.map
        (\newPlayers ->
            League
                { players = newPlayers
                , currentMatch = Nothing
                }
        )
        (Decode.oneOf
            [ playersDecoder
            , -- old format: only players as a dict
              Decode.dict Player.decoder
                |> Decode.map ComparableDict.toList
                |> Decode.map (List.map (\( _, player ) -> ( player.id, player )))
                |> Decode.map (Dict.fromList Player.idSorter)
            ]
        )


playersDecoder : Decoder (Dict PlayerId Player)
playersDecoder =
    Decode.field "players" (Decode.list Player.decoder)
        |> Decode.map (List.map (\player -> ( player.id, player )))
        |> Decode.map (Dict.fromList Player.idSorter)


encode : League -> Encode.Value
encode (League league) =
    Encode.object
        [ ( "players", Encode.list Player.encode (Dict.values league.players) )
        ]



-- PLAYERS


players : League -> List Player
players (League league) =
    Dict.values league.players


getPlayer : PlayerId -> League -> Maybe Player
getPlayer id (League league) =
    Dict.get id league.players


addPlayer : Player -> League -> League
addPlayer player (League league) =
    let
        initialRating =
            case Dict.values league.players |> List.map .rating of
                [] ->
                    Elo.initialRating

                nonEmpty ->
                    List.sum nonEmpty // List.length nonEmpty
    in
    League { league | players = Dict.insert player.id (Player.setRating initialRating player) league.players }


{-| -}
updatePlayer : Player -> League -> League
updatePlayer player (League league) =
    League { league | players = Dict.insert player.id player league.players }


retirePlayer : Player -> League -> League
retirePlayer player (League league) =
    League
        { league
            | players = Dict.remove player.id league.players
            , currentMatch =
                case league.currentMatch of
                    Nothing ->
                        Nothing

                    Just (Match a b) ->
                        if player.name == a.name || player.name == b.name then
                            Nothing

                        else
                            league.currentMatch
        }



-- MATCHES


currentMatch : League -> Maybe Match
currentMatch (League league) =
    league.currentMatch


{-| Select the next match according to a two-phase system:

1.  If there are players who have less than the "play-in" number of matches
    (that is, the number of matches I feel are needed to get a good idea of
    the player's rough ranking) then choose among them randomly, favoring
    those who have played least. If there are no such players then choose
    among all the players, favoring players who have played less recently.

2.  Once the first player is chosen, choose a second player close to them
    by rank. The ideal matchup goes from a tie to a decisive "this player
    is ranked higher."

Edge case: If there are fewer than two unique players, we can't schedule a
new match.

-}
nextMatch : League -> Generator (Maybe Match)
nextMatch (League league) =
    let
        allPlayers =
            Dict.values league.players
    in
    case allPlayers of
        -- at least two
        a :: b :: rest ->
            let
                ( firstPossiblePlayer, restOfPossiblePlayers ) =
                    case List.filter (\player -> player.matches <= playInMatches) allPlayers of
                        [] ->
                            ( a, b :: rest )

                        firstPlayIn :: restOfPlayIns ->
                            ( firstPlayIn, restOfPlayIns )

                mostMatchesAmongPossiblePlayers =
                    List.map .matches (firstPossiblePlayer :: restOfPossiblePlayers)
                        |> List.maximum
                        |> Maybe.withDefault firstPossiblePlayer.matches
            in
            Random.weighted
                ( toFloat (mostMatchesAmongPossiblePlayers - firstPossiblePlayer.matches) ^ 2, firstPossiblePlayer )
                (List.map (\player -> ( toFloat (mostMatchesAmongPossiblePlayers - player.matches) ^ 2, player )) restOfPossiblePlayers)
                |> Random.andThen
                    (\firstPlayer ->
                        let
                            ( head, tail ) =
                                if firstPlayer == a then
                                    ( b, rest )

                                else if firstPlayer == b then
                                    ( a, rest )

                                else
                                    ( a, b :: List.filter (\p -> p /= firstPlayer) rest )

                            furthestAway =
                                (head :: tail)
                                    |> List.map (\player -> abs (firstPlayer.rating - player.rating))
                                    |> List.maximum
                                    |> Maybe.withDefault 0
                        in
                        Random.weighted
                            ( toFloat (furthestAway - abs (firstPlayer.rating - head.rating)) ^ 2, head )
                            (List.map (\player -> ( toFloat (furthestAway - abs (firstPlayer.rating - player.rating)) ^ 2, player )) tail)
                            |> Random.map (Tuple.pair firstPlayer)
                    )
                |> Random.andThen
                    (\( playerA, playerB ) ->
                        Random.map
                            (\flip ->
                                if flip then
                                    Match playerA playerB

                                else
                                    Match playerB playerA
                            )
                            (Random.uniform True [ False ])
                    )
                |> Random.map Just

        -- one or zero players
        _ ->
            Random.constant Nothing


startMatch : Match -> League -> League
startMatch (Match playerA playerB) (League league) =
    League
        { league
            | currentMatch =
                -- don't start a match with players that aren't in the
                -- league...
                Maybe.map2 Tuple.pair
                    (Dict.get playerA.id league.players)
                    (Dict.get playerB.id league.players)
                    |> Maybe.andThen
                        (\( gotA, gotB ) ->
                            -- ... or when the players are the same player
                            if gotA /= gotB then
                                Just (Match gotA gotB)

                            else
                                Nothing
                        )
        }


type Outcome
    = Win { won : Player, lost : Player }
    | Draw { playerA : Player, playerB : Player }


finishMatch : Outcome -> League -> League
finishMatch outcome league =
    case outcome of
        Win { won, lost } ->
            let
                newRatings =
                    Elo.win (kFactor league won)
                        { won = won.rating
                        , lost = lost.rating
                        }
            in
            league
                |> updatePlayer (Player.incrementMatchesPlayed (Player.setRating newRatings.won won))
                |> updatePlayer (Player.incrementMatchesPlayed (Player.setRating newRatings.lost lost))
                |> clearMatch

        Draw { playerA, playerB } ->
            let
                newRatings =
                    Elo.draw (kFactor league (higherRankedPlayer playerA playerB))
                        { playerA = playerA.rating
                        , playerB = playerB.rating
                        }
            in
            league
                |> updatePlayer (Player.incrementMatchesPlayed (Player.setRating newRatings.playerA playerA))
                |> updatePlayer (Player.incrementMatchesPlayed (Player.setRating newRatings.playerB playerB))
                |> clearMatch


{-| -}
playInMatches : Int
playInMatches =
    5


{-| -}
kFactor : League -> Player -> Int
kFactor (League league) player =
    let
        p90 =
            Dict.values league.players
                |> List.map .rating
                |> percentile 0.9
                |> Maybe.withDefault Elo.initialRating
    in
    if player.matches < playInMatches then
        -- players who are new to the league should move around more so that
        -- they can get ranked closer to their actual correct position sooner.
        Elo.sensitiveKFactor * 2

    else if player.rating >= p90 then
        -- players who have been at the top of the rankings for a while should
        -- be stabler. In my use case, I'm picking things to do next. The
        -- "most important" thing to do next doesn't actually change a lot,
        -- and the algorithm should reflect that.
        Elo.sensitiveKFactor // 2

    else
        Elo.sensitiveKFactor


{-| Not 100% correct because of the rounding but good enough for our
purposes.
-}
percentile : Float -> List Int -> Maybe Int
percentile pct items =
    let
        sorted =
            List.sort items

        offset =
            pct * toFloat (List.length items)

        index =
            floor offset
    in
    if toFloat index == offset then
        sorted
            |> List.drop (index - 1)
            |> List.head

    else
        let
            fractionalPart =
                offset - toFloat index

            betweenThese =
                sorted
                    |> List.drop (index - 1)
                    |> List.take 2
        in
        case betweenThese of
            [ a, b ] ->
                Just (round (toFloat a + fractionalPart * (toFloat b - toFloat a)))

            _ ->
                Nothing


{-| -}
higherRankedPlayer : Player -> Player -> Player
higherRankedPlayer a b =
    if a.rating > b.rating then
        a

    else
        b


{-| -}
clearMatch : League -> League
clearMatch (League league) =
    League { league | currentMatch = Nothing }
