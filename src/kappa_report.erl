%%%
%%%   Copyright (c) 2021 Klarna Bank AB (publ)
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%
%%% @doc Klarna Application Analytics.
%%% Functions to generate and print simple human-readable reports from the kappa
%%% specification of the system.
%% @private
-module(kappa_report).

%%%_* Exports ==========================================================
-export([ show_layer/1
        , show_mutes/0
        , show_orphans/0
        , show_owner/1
        , show_ownership/0
        , show_slack_handle/1
        , show_summary/0
        , show_team/1
        ]).

%%%_* Defines ==========================================================
-define(OUTPUT_DONE, output).
-define(NO_OUTPUT, none).

%%%_* Types ============================================================
%% State for capturing if we have alreadu done any output.  Used
%% to possibly insert newlines between sections.
-type output_state() :: ?NO_OUTPUT | ?OUTPUT_DONE.

%%%_* Code =============================================================
%%%_* API --------------------------------------------------------------
%% @doc Show layer of specific application.
-spec show_layer(Application::atom()) -> ok.

show_layer(Application) ->
  case kappa:get_layer(Application) of
    undefined        -> io:format("undefined~n");
    {Layer, Allowed} ->
      io:format("Layer: ~p~nAllowed to call: ~p~n", [Layer, Allowed])
  end.

%% @doc Output summary of teams and the applications they own.
-spec show_ownership() -> output_state().

show_ownership() ->
  output_ownership(?NO_OUTPUT).

%% @doc Output a summary of ownership including any applications that
%% currently lack an owner.
-spec show_summary() -> output_state().

show_summary() ->
  OutState = output_orphans(?NO_OUTPUT),
  output_ownership(OutState).

%% @doc Output list of applications without owners.
-spec show_orphans() -> output_state().

show_orphans() ->
  output_orphans(?NO_OUTPUT).

%% @doc Output list of applications without apis.
-spec show_mutes() -> output_state().

show_mutes() ->
  output_mutes(?NO_OUTPUT).

%% @doc Show owner of a specific module.
-spec show_owner(Module::atom()) -> ok.

show_owner(Module) ->
  io:format("~p~n", [kappa:get_owner(Module)]).

%% @doc Show applications owned by specific team
-spec show_team(atom()) -> output_state().

show_team(Team) ->
  output_ownership(get_descriptions([Team]), ?NO_OUTPUT).

%% @doc Show the slack handle(s) for a specific team
-spec show_slack_handle(atom()) -> ok.
show_slack_handle(Team) ->
  Props = kappa:get_properties(Team),
  SlackHandles = proplists:get_value(slack_handle, Props, []),
  lists:foreach(fun(Handle) -> io:format("~s~n", [Handle]) end,
               SlackHandles).

%%%_* Internals --------------------------------------------------------
%% @doc Get descrptions for teams listed.  Each description consists
%% of team name, alarm email(s) and a list of applications.
-spec get_descriptions([atom()]) -> [{atom(), list(), list()}].

get_descriptions(Owners) ->
  [{Owner,
    kappa:get_properties(Owner),
    kappa:get_assets(Owner, apps)}
   || Owner <- Owners].

%% @doc Output descriptions for every team that own applications.
-spec output_ownership(output_state()) -> output_state().

output_ownership(State) ->
  output_ownership(get_descriptions(kappa:get_owners()), State).

%% @doc Output descriptions for teams listed.  Teams that
%% do not own any applications are not shown.
-spec output_ownership(Descriptions::[{atom(), list(), list()}], output_state())
                      -> output_state().

output_ownership(Descriptors, OutState) ->
  Keep = fun({_, _, Apps}) -> Apps =/= [] end,
  case lists:filter(Keep, Descriptors) of
    [] -> OutState;
    Output ->
      F = fun({Owner, Properties, Apps}, State) ->
              maybe_nl(State),
              io:format("Team: ~p~n", [Owner]),
              lists:foreach(fun({Prop, Value}) ->
                                io:format(" ~p: ~p~n", [Prop, Value])
                            end,
                            Properties),
              io:format(" Applications (~p): ~p~n", [length(Apps), Apps]),
              ?OUTPUT_DONE
          end,
      lists:foldl(F, OutState, Output)
  end.

%% @doc Output list of orphaned applications with header.  Nothing is
%% output if there are no orphans.
-spec output_orphans([atom()], output_state()) -> output_state().

output_orphans([], State) -> State;
output_orphans(Orphans, State) ->
  maybe_nl(State),
  io:format("Orphaned applications: ~p~n", [Orphans]),
  ?OUTPUT_DONE.

output_orphans(State) ->
  output_orphans(kappa:get_assets(undefined, apps), State).

output_mutes([], State) -> State;
output_mutes(Mutes, State) ->
  maybe_nl(State),
  lists:foreach(fun({Team, Apps}) ->
                    io:format("~p: ~p~n", [Team, Apps])
                end,
                Mutes),
  ?OUTPUT_DONE.

output_mutes(State) ->
  MutesByTeam = collect_by_team(kappa:get_mutes()),
  output_mutes(MutesByTeam, State).

collect_by_team(Mutes) ->
  Dict = dict:new(),
  D2 = lists:foldl(fun({Team, App}, D) -> dict:append(Team, App, D) end,
                   Dict,
                   Mutes),
  lists:sort(dict:to_list(D2)).

%% @doc Output a nl if we have previous output.
-spec maybe_nl(output_state()) -> ok.

maybe_nl(?OUTPUT_DONE) -> io:nl();
maybe_nl(?NO_OUTPUT) -> ok.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
