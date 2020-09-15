module League exposing
    ( League, init, decoder, encode
    , players, addPlayer, retirePlayer
    , Match(..), currentMatch, nextMatch, startMatch, Outcome(..), finishMatch
    )

{-|

@docs League, init, decoder, encode

@docs players, addPlayer, retirePlayer

@docs Match, currentMatch, nextMatch, startMatch, Outcome, finishMatch

-}

import Dict exposing (Dict)
import Elo
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import List.Extra
import Player exposing (Player)
import Random exposing (Generator)


type League
    = League
        { players : Dict String Player
        , currentMatch : Maybe Match
        }


type Match
    = Match Player Player



-- LOADING AND SAVING


init : League
init =
    League
        { players = Dict.empty
        , currentMatch = Nothing
        }


decoder : Decoder League
decoder =
    Decode.map
        (\newPlayers -> League { players = newPlayers, currentMatch = Nothing })
        (Decode.oneOf
            [ Decode.field "players" (Decode.list Player.decoder)
                |> Decode.map (List.map (\player -> ( player.name, player )))
                |> Decode.map Dict.fromList
            , -- old formats
              Decode.dict Player.decoder
            ]
        )


encode : League -> Encode.Value
encode (League league) =
    Encode.object
        [ ( "players", Encode.list Player.encode (Dict.values league.players) ) ]



-- PLAYERS


players : League -> List Player
players (League league) =
    Dict.values league.players


addPlayer : Player -> League -> League
addPlayer player (League league) =
    League { league | players = Dict.insert player.name player league.players }


{-| Chesterton's export
-}
updatePlayer : Player -> League -> League
updatePlayer =
    addPlayer


retirePlayer : Player -> League -> League
retirePlayer player (League league) =
    League
        { league
            | players = Dict.remove player.name league.players
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


nextMatch : League -> Generator (Maybe Match)
nextMatch (League league) =
    let
        allPlayers =
            Dict.values league.players

        minimumMatches =
            allPlayers
                |> List.map .matches
                |> List.minimum
                |> Maybe.withDefault 0

        leastPlayed =
            allPlayers
                |> List.filter (\player -> player.matches == minimumMatches)
    in
    case allPlayers of
        a :: b :: rest ->
            allPlayers
                |> List.Extra.uniquePairs
                |> List.filter (\( left, right ) -> List.member left leastPlayed || List.member right leastPlayed)
                |> List.map
                    (\( left, right ) ->
                        ( toFloat <| abs (left.rating - right.rating)
                        , ( left, right )
                        )
                    )
                |> -- flip the ordering so that the smallest gap / match adjustment is the most
                   -- likely to be picked.
                   (\weights ->
                        let
                            maxDiff =
                                List.maximum (List.map Tuple.first weights) |> Maybe.withDefault (10 ^ 9)
                        in
                        List.map (\( diff, pair ) -> ( (maxDiff - diff) ^ 2, pair )) weights
                   )
                |> (\weights ->
                        case weights of
                            firstWeight :: restOfWeights ->
                                Random.weighted firstWeight restOfWeights

                            _ ->
                                -- how did we get here? Unless... a and b were the same
                                -- player? Sneaky caller!
                                Random.constant ( a, b )
                   )
                |> Random.map (\( left, right ) -> Match left right)
                |> Random.map Just

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
                    (Dict.get playerA.name league.players)
                    (Dict.get playerB.name league.players)
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
                    Elo.win Elo.sensitiveKFactor { won = won.rating, lost = lost.rating }
            in
            league
                |> updatePlayer (Player.incrementMatchesPlayed (Player.setRating newRatings.won won))
                |> updatePlayer (Player.incrementMatchesPlayed (Player.setRating newRatings.lost lost))
                |> clearMatch

        Draw { playerA, playerB } ->
            let
                newRatings =
                    Elo.draw Elo.sensitiveKFactor
                        { playerA = playerA.rating
                        , playerB = playerB.rating
                        }
            in
            league
                |> updatePlayer (Player.incrementMatchesPlayed (Player.setRating newRatings.playerA playerA))
                |> updatePlayer (Player.incrementMatchesPlayed (Player.setRating newRatings.playerB playerB))
                |> clearMatch


{-| Chesterton's export
-}
clearMatch : League -> League
clearMatch (League league) =
    League { league | currentMatch = Nothing }
