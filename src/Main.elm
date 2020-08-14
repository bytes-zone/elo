module Main exposing (..)

import Accessibility.Styled as Html exposing (Html)
import Browser exposing (Document)
import Dict exposing (Dict)
import Elo
import Html.Styled as WildWildHtml
import Html.Styled.Events as Events
import List.Extra
import Player exposing (Player)
import Random exposing (Generator)


type alias Flags =
    ()


type alias Model =
    { players : Dict String Player

    -- view state: what match are we playing now?
    , currentMatch : Maybe ( Player, Player )

    -- view state: new player form
    , newPlayerName : String
    }


type Msg
    = KeeperUpdatedNewPlayerName String
    | KeeperWantsToAddNewPlayer
    | StartMatchBetween ( Player, Player )


init : Flags -> ( Model, Cmd Msg )
init _ =
    ( { players =
            Dict.fromList
                [ ( "a", Player.init "a" )
                , ( "b", Player.init "b" )
                , ( "c", Player.init "c" )
                , ( "d", Player.init "d" )
                ]
      , currentMatch = Nothing
      , newPlayerName = ""
      }
    , Cmd.none
    )
        |> startNextMatchIfPossible


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        KeeperUpdatedNewPlayerName newPlayerName ->
            ( { model | newPlayerName = newPlayerName }
            , Cmd.none
            )

        KeeperWantsToAddNewPlayer ->
            ( { model
                | players = Dict.insert model.newPlayerName (Player.init model.newPlayerName) model.players
                , newPlayerName = ""
              }
            , Cmd.none
            )

        StartMatchBetween players ->
            ( { model | currentMatch = Just players }
            , Cmd.none
            )


startNextMatchIfPossible : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
startNextMatchIfPossible ( model, cmd ) =
    if model.currentMatch /= Nothing then
        -- there's a match already in progress; no need to overwrite it.
        ( model, cmd )

    else
        let
            players =
                Dict.values model.players
        in
        case players of
            first :: next :: rest ->
                ( model
                , Cmd.batch
                    [ cmd
                    , Random.generate StartMatchBetween (match first next rest)
                    ]
                )

            _ ->
                ( model, cmd )


{-| We need at least two players to guarantee that we return two distinct
players.

In the future, we might want to consider the players with the closest rankings
ahead of the players with the fewest matches. We'll see.

-}
match : Player -> Player -> List Player -> Generator ( Player, Player )
match a b rest =
    (a :: b :: rest)
        |> List.Extra.uniquePairs
        |> List.map
            (\( left, right ) ->
                ( ((10 ^ 9) - abs (left.rating - right.rating) |> toFloat)
                    / (toFloat (left.matches + right.matches) / 2)
                , ( left, right )
                )
            )
        |> (\pairs ->
                case pairs of
                    first :: restPairs ->
                        Random.weighted first restPairs

                    _ ->
                        -- how did we get here? Unless... a and b were the same
                        -- player? Sneaky caller!
                        Random.constant ( a, b )
           )


view : Model -> Document Msg
view model =
    { title = "ELO Anything!"
    , body =
        [ Html.main_ []
            [ rankings (Dict.values model.players)
            , newPlayerForm model
            , case model.currentMatch of
                Just ( playerA, playerB ) ->
                    Html.text (playerA.name ++ " vs. " ++ playerB.name)

                Nothing ->
                    Html.text "no match right now... add some players, maybe?"
            ]
            |> Html.toUnstyled
        ]
    }


rankings : List Player -> Html msg
rankings players =
    players
        |> List.sortBy .rating
        |> List.indexedMap
            (\rank player ->
                Html.tr
                    []
                    [ Html.td [] [ Html.text (String.fromInt (rank + 1)) ]
                    , Html.td [] [ Html.text player.name ]
                    , Html.td [] [ Html.text (String.fromInt player.rating) ]
                    , Html.td [] [ Html.text (String.fromInt player.matches) ]
                    ]
            )
        |> (::)
            (Html.tr
                []
                [ Html.th [] [ Html.text "Rank" ]
                , Html.th [] [ Html.text "Name" ]
                , Html.th [] [ Html.text "Rating" ]
                , Html.th [] [ Html.text "Matches" ]
                ]
            )
        |> Html.table []


newPlayerForm : { whatever | newPlayerName : String } -> Html Msg
newPlayerForm form =
    WildWildHtml.form
        [ Events.onSubmit KeeperWantsToAddNewPlayer ]
        [ Html.labelBefore
            []
            (Html.text "Player Name:")
            (Html.inputText form.newPlayerName [ Events.onInput KeeperUpdatedNewPlayerName ])
        , Html.button [] [ Html.text "Add Player" ]
        ]


main : Program Flags Model Msg
main =
    Browser.document
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }
