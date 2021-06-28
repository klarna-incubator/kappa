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
%%% @doc Functions to handle changes in kappa.edges cache files of 2 OTP releases
%%%
%%% They were mainly usefull before Erlang introduced `code:atomic_load/1`.
-module(upgrade_analysis).

%% API
-export([ check_upgrade/2
        ]).

%%% Includes ===========================================================

-include("kappa.hrl").

%%% Types ==============================================================

-record(state, { identified_deps = sets:new()
               , declared_deps   = dict:new()
               , all_mods        = sets:new()
               , new_mods        = sets:new()
               }).

-record(load_dep, { from   :: module()
                  , to     :: module()
                  , caller :: mfa()
                  , called :: mfa()
                  , type   :: new | removed | {indirect, [[mfa(), ...], ...]}
                  }).

-define(MAX_INDIRECT_PATHS, 5).
-define(APPLICATION, kappa).

%%% API ================================================================

check_upgrade(BaselineCache, Cache) ->
  State = init_state(BaselineCache, Cache),
  Checks = [ fun find_load_dependency_cycles/1
           , fun find_load_dependencies_missing_from_up_files/1
           , fun find_load_dependencies_on_deleted_modules/1
           ],
  Procs = max(2, erlang:system_info(schedulers_online) div 2),
  Warns = klib_parallel:map(fun(Check) -> Check(State) end, Checks, Procs),
  case lists:flatten(Warns) of
    []  -> ok;
    Msg ->
      %% start the message with an extra newline for better
      %% readability when the test is called from make
      io:put_chars(standard_error, [$\n, Msg]),
      error
  end.

%%% Helper functions ===================================================

init_state(BaselineCache, Cache) ->
  %% Read the cache files
  #cache{ fun_edges = BaselineEdges
        , exports   = BaselineExports
        , checksum  = BaselineChecksum
        } = kappa_edge_cache:read_cache_file(BaselineCache),
  #cache{ fun_edges         = Edges
        , exports           = Exports
        , checksum          = Checksum
        , load_orders       = AllLoadOrders
        , non_upgrade_calls = AllNonCalls
        } = kappa_edge_cache:read_cache_file(Cache),
  if BaselineExports =:= [];
     BaselineEdges   =:= [] -> error({failed_to_read, BaselineCache});
     Exports         =:= [];
     Edges           =:= [] -> error({failed_to_read, Cache});
     true                   -> ok
  end,
  %% Calculate the delta between the baseline and the current release
  Mod2App            = checksum_to_appmap(Checksum),
  ExportsSet         = sets:from_list(Exports),
  BaselineExportsSet = sets:from_list(BaselineExports),
  NewAPI             = sets:subtract(ExportsSet, BaselineExportsSet),
  RemovedAPI         = sets:subtract(BaselineExportsSet, ExportsSet),
  ModSet             = checksum_to_modset(Checksum),
  BaselineModSet     = checksum_to_modset(BaselineChecksum),
  NewMods            = sets:subtract(ModSet, BaselineModSet),
  %% Read info on code excluded from the module load race analysis
  Exclusions = module_load_race_check_exclusions(),
  %% Get upgrade attributes from new UP files
  LoadOrders = lists:foldl(
                 fun ({Mod, LoadOrder}, Acc) ->
                     case sets:is_element(Mod, NewMods)
                       andalso dict:fetch(Mod, Mod2App) =:= upgrade of
                       true  -> dict:append(LoadOrder, Mod, Acc);
                       false -> Acc
                     end
                 end,
                 dict:new(),
                 AllLoadOrders),
  NonCalls   = lists:foldl(
                 fun ({Mod, NonCall}, Acc) ->
                     case sets:is_element(Mod, NewMods)
                       andalso dict:fetch(Mod, Mod2App) =:= upgrade of
                       true  -> sets:add_element(NonCall, Acc);
                       false -> Acc
                     end
                 end,
                 sets:new(),
                 AllNonCalls),
  %% Calculate the dependencies and load instructions
  NewAPIDeps = [#load_dep{ from   = FromM
                         , to     = ToM
                         , caller = Caller
                         , called = Called
                         , type   = new
                         }
                || #edge{ from = {ToM,   _, _} = Caller
                        , to   = {FromM, _, _} = Called
                        } <- Edges,
                   FromM =/= ToM,
                   sets:is_element(Called, NewAPI),
                   %% Discard white listed calls
                   not sets:is_element({Caller, Called}, NonCalls),
                   not is_excluded_function(Caller, Exclusions, Mod2App),
                   not is_excluded_function(Called, Exclusions, Mod2App)
               ],
  RemovedAPIDeps = [#load_dep{ from   = FromM
                             , to     = ToM
                             , caller = Caller
                             , called = Called
                             , type   = removed
                             }
                    || #edge{ from = {FromM, _, _} = Caller
                            , to   = {ToM,   _, _} = Called
                            } <- BaselineEdges,
                       FromM =/= ToM,
                       sets:is_element(Called, RemovedAPI),
                       %% We don't care about calls to removed
                       %% modules. Removed modules will be deleted
                       %% after loading the new version of every other
                       %% module anyway, so this dependency is always
                       %% fulfilled
                       sets:is_element(ToM, ModSet),
                       %% We also don't care about calls from removed
                       %% modules, for obvious reasons
                       sets:is_element(FromM, ModSet),
                       %% Discard white listed calls
                       not sets:is_element({Caller, Called}, NonCalls),
                       not is_excluded_function(Caller, Exclusions, Mod2App),
                       not is_excluded_function(Called, Exclusions, Mod2App)
                   ],
  ApiDeps = sets:from_list(NewAPIDeps ++ RemovedAPIDeps),
  #state{ identified_deps = ApiDeps
        , declared_deps   = LoadOrders
        , new_mods        = NewMods
        , all_mods        = ModSet
        }.

find_load_dependency_cycles(State) ->
  %% Build a graph containing both the identified and declared load
  %% dependencies
  G = digraph:new(),
  add_identified_deps_to_graph(G, State),
  add_declared_deps_to_graph(G, State),
  %% G must be a DAG, in other words there must be no strong
  %% components in it
  Components = digraph_utils:cyclic_strong_components(G),
  Warns =
    [io_lib:format("Circular module load dependencies: "
                   "~s\n~s\n",
                   [ format_load_dep_cycle(Cycle, G)
                   , circular_load_dep_advice()
                   ])
     || Cycle <- Components],
  digraph:delete(G),
  Warns.

find_load_dependencies_missing_from_up_files(State) ->
  %% Build a graph of declared load dependencies
  GDecl = add_declared_deps_to_graph(digraph:new(), State),
  %% Each load dependency we identified must be covered by some UP
  %% file declarations. In other words there must be a path between
  %% the two modules.
  %%
  %% Because there can be multiple function calls introducing load
  %% dependencies between two modules, we will perform the analysis on
  %% the graph of identified dependencies, instead of the dependency
  %% set alone.
  GId = add_identified_deps_to_graph(digraph:new(), State),
  MissingDeps = [digraph:edge(GId, E)
                 || E = {FromM, ToM} <- digraph:edges(GId),
                    digraph:get_path(GDecl, FromM, ToM) =:= false
                ],
  digraph:delete(GDecl),
  digraph:delete(GId),
  [io_lib:format("Module load race condition: ~s\n~s\n",
                 [ format_load_dep_edge(Edge)
                 , missing_load_dep_advice(Edge)
                 ])
   || Edge <- MissingDeps
  ].

find_load_dependencies_on_deleted_modules(#state{ declared_deps  = Deps
                                                , all_mods       = Mods
                                                }) ->
  %% UP files shall not declare load dependencies on modules that do
  %% not exist (e.g. have been removed)
  DepsOnDeletedMods =
    dict:fold(fun ({FromM, ToM}, UpMods, Acc) ->
                  [{UpMod, M}
                   || M <- [FromM, ToM],
                      not sets:is_element(M, Mods),
                      UpMod <- UpMods
                  ] ++ Acc
              end,
              [],
              Deps),
  [io_lib:format("Load order declaration for "
                 "removed module in UP file ~w: ~w\n",
                 [UpMod, M])
   || {UpMod, M} <- DepsOnDeletedMods
  ].

missing_load_dep_advice({_Edge, FromM, ToM, Labels}) ->
  Exceptions = [{Caller, Called}
                || #load_dep{caller = Caller, called = Called} <- Labels
               ],
  Advs =
    [ io_lib:format("add '-load_order([{~w,~w}]).' to an UP file",
                    [FromM, ToM])

    , io_lib:format("if these calls may not happen during this upgrade,"
                    " add '-non_upgrade_call(~w).' to an UP file",
                    [Exceptions])

    , "if one of these functions/modules/applications is never used during"
      " an upgrade, an exception may be added to"
      " 'module_load_race_check_exclusions.eterm'"
    ],
  format_advice_list(Advs).

circular_load_dep_advice() ->
  Advs =
    [ "try to restructure the code to avoid the circular load dependencies"

    , "try to distribute the changes over multiple releases"

    , "if one of these calls may not happen during this upgrade,"
      " add a '-non_upgrade_call([...]).' declaration to an UP file"

    , "if one of these functions/modules/applications is never used during"
      " an upgrade, an exception may be added to"
      " 'module_load_race_check_exclusions.eterm'"
    ],
  format_advice_list(Advs).

format_advice_list(Advs) ->
  %% Add a bullet point to the beginning, and a new line to the end of
  %% each advice
  [[" * ", Adv, "\n"] || Adv <- Advs].

format_load_dep_cycle(Cycle = [Mod | _], G) ->
  [FirstEdge | Edges] = vertices_to_edges(Cycle ++ [Mod], G),
  [format_load_dep_edge(FirstEdge)]
    ++ lists:map(fun format_load_dep_edge_no_head/1, Edges).

format_load_dep_edge(Edge = {_, FromM, _ToM, _Labels}) ->
  io_lib:format("~w~s",
                [FromM, format_load_dep_edge_no_head(Edge)]).

format_load_dep_edge_no_head({_, _FromM, ToM, Labels}) ->
  io_lib:format(" -> ~w (~s)",
                [ToM, format_load_dep_edge_labels(Labels)]).

format_load_dep_edge_labels(Labels) ->
  string:join([lists:flatten(format_load_dep_edge_label(Label))
               || Label <- Labels],
              "; ").

format_load_dep_edge_label(#load_dep{ caller = Caller
                                    , called = Called
                                    , type   = {indirect, Pathes}
                                    }) ->
  io_lib:format("~s accesses new API ~s indirectly, via new modules (~s)",
                [ format_mfa(Caller)
                , format_mfa(Called)
                , format_indirect_pathes(Pathes)]);
format_load_dep_edge_label(#load_dep{ caller = Caller
                                    , called = Called
                                    , type   = Type
                                    }) ->
  io_lib:format("~s calls ~s API ~s",
                [format_mfa(Caller), Type, format_mfa(Called)]);
format_load_dep_edge_label(UpMod) ->
  io_lib:write(UpMod).

format_indirect_pathes(Pathes) ->
  string:join([lists:flatten(format_indirect_path(Path))
               || Path <- Pathes],
              "; ").

format_indirect_path([MFA | Path]) ->
  [format_mfa(MFA) | format_indirect_path_with_arrow(Path)].

format_indirect_path_with_arrow([]) ->
  [];
format_indirect_path_with_arrow([MFA | Path]) ->
  [" -> ", format_mfa(MFA) | format_indirect_path_with_arrow(Path)].

format_mfa({M, F, A}) ->
  io_lib:format("~w:~w/~p", [M, F, A]).

vertices_to_edges([V1, V2 | Vs], G) ->
  case digraph:edge(G, {V1, V2}) of
    false ->
      %% There's no direct edge from V1 to V2: look for a path instead!
      Path = digraph:get_short_path(G, V1, V2),
      true = is_list(Path),   % assert
      vertices_to_edges(Path ++ Vs, G);
    Edge ->
      [Edge | vertices_to_edges([V2 | Vs], G)]
  end;
vertices_to_edges(_LessThanTwoVertices, _G) ->
  [].

add_identified_deps_to_graph(G0,
                             #state{ identified_deps = Deps
                                   , new_mods        = NewMods
                                   }) ->
  %% Add all the edges
  sets:fold(
    fun (#load_dep{from = FromM, to = ToM} = Dep, G) ->
        %% Make sure the modules are present in the graph as vertices
        digraph:add_vertex(G, FromM),
        digraph:add_vertex(G, ToM),
        %% Add the dependency to the edge's label (the edge may or may
        %% not exist already)
        E = {FromM, ToM},
        Label = case digraph:edge(G, E) of
                  false                      -> [Dep];
                  {E, FromM, ToM, OldLabels} -> [Dep | OldLabels]
                end,
        digraph:add_edge(G, E, FromM, ToM, Label),
        G
    end,
    G0,
    Deps),
  %% Connect all in-neighbours and out-neighbours of new modules
  %% directly, then remove edges through new modules
  sets:fold(
    fun (Mod, G) ->
        %% Collect
        InDeps  = take_load_deps_from_edges(G, digraph:in_edges(G, Mod)),
        OutDeps = take_load_deps_from_edges(G, digraph:out_edges(G, Mod)),
        %% Connect all in neighbours with all out neighbours directly
        [begin
           E   = {FromM, ToM},
           Ind = limit(merge_indirections(InType, OutType, Via),
                       ?MAX_INDIRECT_PATHS),
           Dep = #load_dep{ from   = FromM
                          , to     = ToM
                          , caller = Caller
                          , called = Called
                          , type   = {indirect, Ind}
                          },
           Label = case digraph:edge(G, E) of
                     false ->
                       [Dep];
                     {E, FromM, ToM, OldLabels} ->
                       merge_indirect_load_deps(Dep, OldLabels)
                   end,
           digraph:add_edge(G, E, FromM, ToM, Label)
         end
         || #load_dep{ from   = FromM
                     , called = Called
                     , type   = InType
                     } <- InDeps,
            #load_dep{ to     = ToM
                     , caller = Caller
                     , called = Via
                     , type   = OutType
                     } <- OutDeps,
            FromM =/= ToM
        ],
        G
    end,
    G0,
    NewMods).

limit(Paths, Max) -> lists:sublist(Paths, Max).

merge_indirections({indirect, InPathes}, {indirect, OutPathes}, Via) ->
  [OutPath ++ [Via] ++ InPath || OutPath <- OutPathes, InPath <- InPathes];
merge_indirections({indirect, InPathes}, new, Via) ->
  [[Via | InPath] || InPath <- InPathes];
merge_indirections(new, {indirect, OutPathes}, Via) ->
  [OutPath ++ [Via] || OutPath <- OutPathes];
merge_indirections(new, new, Via) ->
  [[Via]].

merge_indirect_load_deps(Dep, []) ->
  [Dep];
merge_indirect_load_deps(#load_dep{ caller = Caller
                                  , called = Called
                                  , type   = {indirect, NewVias}
                                  },
                         [Dep = #load_dep{ caller = Caller
                                         , called = Called
                                         , type   = {indirect, OldVias}
                                         }
                          | Labels]) ->
  [Dep#load_dep{type = {indirect, OldVias ++ NewVias}} | Labels];
merge_indirect_load_deps(Dep, [Label | Labels]) ->
  [Label | merge_indirect_load_deps(Dep, Labels)].

take_load_deps_from_edges(G, Edges) ->
  [LoadDep
   || Edge    <- Edges,
      LoadDep <- begin
                   {Edge, FromM, ToM, Labels} = digraph:edge(G, Edge),
                   case lists:partition(fun (#load_dep{}) -> true;
                                            (_) -> false
                                        end, Labels) of
                     {[], _NonLoadDeps} ->
                       [];
                     {LoadDeps, []} ->
                       digraph:del_edge(G, Edge),
                       LoadDeps;
                     {LoadDeps, NonLoadDeps} ->
                       digraph:add_edge(G, Edge, FromM, ToM, NonLoadDeps),
                       LoadDeps
                   end
                 end
  ].

add_declared_deps_to_graph(G0, #state{declared_deps = Deps}) ->
  dict:fold(
    fun ({FromM, ToM}, UpMods, G) ->
        %% Make sure the modules are present in the graph as vertices
        digraph:add_vertex(G, FromM),
        digraph:add_vertex(G, ToM),
        %% Add the UP files to the edge's label (the edge may or may
        %% not exist already)
        E = {FromM, ToM},
        Label = case digraph:edge(G, E) of
                  false                      -> UpMods;
                  {E, FromM, ToM, OldLabels} -> UpMods ++ OldLabels
                end,
        digraph:add_edge(G, E, FromM, ToM, Label),
        G
    end,
    G0,
    Deps).

module_load_race_check_exclusions() ->
  File = application:get_env(?APPLICATION, module_load_race_check_exclusions_file,
                             "module_load_race_check_exclusions.eterm"),
  {ok, Exclusions} = file:consult(File),
  dict:from_list(
    [{ App
     , if Mods =:= all -> all;
          true         -> dict:from_list(
                            [{ Mod
                             , if Funs =:= all -> all;
                                  true         -> sets:from_list(Funs)
                               end}
                             || {Mod, Funs} <- Mods])
           end}
     || {application, App, Mods} <- Exclusions
    ]).

is_excluded_function({M, _F, _A} = Fun, Exclusions, Mod2App) ->
  App = dict:fetch(M, Mod2App),
  case dict:find(App, Exclusions) of
    error      -> false;
    {ok, all}  -> true;
    {ok, Mods} -> case dict:find(M, Mods) of
                    error      -> false;
                    {ok, all}  -> true;
                    {ok, Funs} -> sets:is_element(Fun, Funs)
                  end
  end.

checksum_to_appmap(Checksum) ->
  dict:from_list([file_to_app_and_mod(File) || {File, _MD5} <- Checksum]).

checksum_to_modset(Checksum) ->
  sets:from_list([file_to_mod(File) || {File, _MD5} <- Checksum]).

file_to_mod(File) ->
  list_to_atom(filename:basename(File, code:objfile_extension())).

file_to_app_and_mod(File) ->
  [ModStr, _Ebin, AppStr | _] = lists:reverse(filename:split(File)),
  Mod = list_to_atom(filename:rootname(ModStr, code:objfile_extension())),
  App = list_to_atom(AppStr),
  {Mod, App}.

%%% Unit tests =========================================================

-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).

new_modules_in_deps_graph_test_() ->
  %% Test example:
  Deps = [ %% 3 new modules (n1, n2 and n3) all call each other
           #load_dep{ from   = n1
                    , to     = n2
                    , caller = {n2, internal, 0}
                    , called = {n1, internal, 0}
                    , type   = new
                    }
         , #load_dep{ from   = n1
                    , to     = n3
                    , caller = {n3, internal, 0}
                    , called = {n1, internal, 0}
                    , type   = new
                    }
         , #load_dep{ from   = n2
                    , to     = n1
                    , caller = {n1, internal, 0}
                    , called = {n2, internal, 0}
                    , type   = new
                    }
         , #load_dep{ from   = n2
                    , to     = n3
                    , caller = {n3, internal, 0}
                    , called = {n2, internal, 0}
                    , type   = new
                    }
         , #load_dep{ from   = n3
                    , to     = n1
                    , caller = {n1, internal, 0}
                    , called = {n3, internal, 0}
                    , type   = new
                    }
         , #load_dep{ from   = n3
                    , to     = n2
                    , caller = {n2, internal, 0}
                    , called = {n3, internal, 0}
                    , type   = new
                    }

           %% each new module calls into the new API of an old module
           %% with the same index (o1, o2 and o3 respectively)
         , #load_dep{ from   = o1
                    , to     = n1
                    , caller = {n1, internal, 0}
                    , called = {o1, external, 0}
                    , type   = new
                    }
         , #load_dep{ from   = o2
                    , to     = n2
                    , caller = {n2, internal, 0}
                    , called = {o2, external, 0}
                    , type   = new
                    }
         , #load_dep{ from   = o3
                    , to     = n3
                    , caller = {n3, internal, 0}
                    , called = {o3, external, 0}
                    , type   = new
                    }

           %% only o1 and o4 old modules call new modules (n1 and n2
           %% respectively)
         , #load_dep{ from   = n1
                    , to     = o1
                    , caller = {o1, internal, 0}
                    , called = {n1, external, 0}
                    , type   = new
                    }
         , #load_dep{ from   = n2
                    , to     = o4
                    , caller = {o4, internal, 0}
                    , called = {n2, external, 0}
                    , type   = new
                    }
         ],
  Decls = [ {o2, o1}
          , {o2, o4}
          , {o3, o1}
          , {o3, o4}
          , {o1, o4}
          ],
  S1 = #state{ identified_deps = sets:from_list(Deps)
             , new_mods        = sets:from_list([n1, n2, n3])
             },
  S2 = S1#state{ declared_deps = dict:from_list([{Decl, [foo_UP]}
                                                 || Decl <- Decls])
               },
  [ ?_test(begin
             G = digraph:new(),
             try
               add_identified_deps_to_graph(G, S1),
               ?assertEqual([ %% The expected outcome:
                              %%
                              %% - o2 and o3 shall be loaded first
                              %%   (before o1 and o4), since they may
                              %%   be called from the new modules
                              %% - o1 needs to be loaded before o4,
                              %%   because it may be called from the
                              %%   new modules
                              {o1, o4}
                            , {o2, o1}
                            , {o2, o4}
                            , {o3, o1}
                            , {o3, o4}
                            ],
                            lists:sort(digraph:edges(G)))
             after
               digraph:delete(G)
             end
           end)
  , ?_assertMatch( []
                 , find_load_dependency_cycles(S1))
  , ?_assertMatch( [_, _, _, _, _]
                 , find_load_dependencies_missing_from_up_files(S1))
  , ?_assertMatch( []
                 , find_load_dependencies_missing_from_up_files(S2))
  ].

load_depdendency_cycles_test_() ->
  [ %% There are no cycles in an empty graph
    ?_assertMatch( []
                 , find_load_dependency_cycles(
                     deps2state( []
                               , []
                               )))
    %% Simple graph with no cycles
  , ?_assertMatch( []
                 , find_load_dependency_cycles(
                     deps2state( [{a, b}, {b, c}]
                               , [{a, c}]
                               )))
    %% Cyclic dependencies between the modules
  , ?_assertMatch( [_]
                 , find_load_dependency_cycles(
                     deps2state( [{a, b}, {b, c}, {c, a}]
                               , []
                               )))
  , ?_assertMatch( [_, _]
                 , find_load_dependency_cycles(
                     deps2state( [{a, b}, {b, c}, {c, a}, {d, e}, {e, d}]
                               , []
                               )))
    %% Contradicting UP file instructions
  , ?_assertMatch( [_]
                 , find_load_dependency_cycles(
                     deps2state( []
                               , [{a, b}, {b, c}, {c, a}]
                               )))
  , ?_assertMatch( [_, _]
                 , find_load_dependency_cycles(
                     deps2state( []
                               , [{a, b}, {b, c}, {c, a}, {d, e}, {e, d}]
                               )))
    %% Incorrect UP file instructions
  , ?_assertMatch( [_]
                 , find_load_dependency_cycles(
                     deps2state( [{a, b}, {b, c}]
                               , [{c, a}]
                               )))
  , ?_assertMatch( [_, _]
                 , find_load_dependency_cycles(
                     deps2state( [{a, b}, {b, c}, {e, d}]
                               , [{c, a}, {d, e}]
                               )))
  ].

load_dependencies_missing_from_up_files_test_() ->
  [ %% There are no declarations needed for an empty graph
    ?_assertMatch( []
                 , find_load_dependencies_missing_from_up_files(
                     deps2state( []
                               , []
                               )))
    %% All dependencies are declared
  , ?_assertMatch( []
                 , find_load_dependencies_missing_from_up_files(
                     deps2state( [{a, b}, {b, c}, {d, e}]
                               , [{a, b}, {b, c}, {d, e}]
                               )))
    %% More dependencies are declared than discovered
  , ?_assertMatch( []
                 , find_load_dependencies_missing_from_up_files(
                     deps2state( [{a, c}]
                               , [{a, b}, {b, c}, {d, e}]
                               )))
    %% Missing declarations
  , ?_assertMatch( [_]
                 , find_load_dependencies_missing_from_up_files(
                     deps2state( [{a, b}, {b, c}, {d, e}]
                               , [{b, c}, {d, e}]
                               )))
  , ?_assertMatch( [_, _]
                 , find_load_dependencies_missing_from_up_files(
                     deps2state( [{a, b}, {b, c}, {d, e}]
                               , [{d, e}]
                               )))
  , ?_assertMatch( [_, _, _]
                 , find_load_dependencies_missing_from_up_files(
                     deps2state( [{a, b}, {b, c}, {d, e}]
                               , []
                               )))
  ].

load_dependencies_on_deleted_modules_test_() ->
  [ %% No declared dependencies trigger no warnings
    ?_assertMatch( []
                 , find_load_dependencies_on_deleted_modules(
                     deps2state( []
                               , []
                               , [a, b, c, d, e]
                               )))
  , ?_assertMatch( []
                 , find_load_dependencies_on_deleted_modules(
                     deps2state( [{a, b}, {b, c}]
                               , []
                               , [a, b, c, d, e]
                               )))
    %% All declared dependencies are OK
  , ?_assertMatch( []
                 , find_load_dependencies_on_deleted_modules(
                     deps2state( []
                               , [{a, b}, {b, c}, {d, e}]
                               , [a, b, c, d, e]
                               )))
    %% Declared dependencies on deleted modules
  , ?_assertMatch( [_]
                 , find_load_dependencies_on_deleted_modules(
                     deps2state( []
                               , [{a, b}, {b, c}]
                               , [a, b]
                               )))
  , ?_assertMatch( [_, _]
                 , find_load_dependencies_on_deleted_modules(
                     deps2state( []
                               , [{a, b}, {b, c}, {d, a}]
                               , [a, b]
                               )))
  ].

deps2state(Identified, Declared) ->
  Mods = lists:usort([M || {M1, M2} <- Identified ++ Declared, M <- [M1, M2]]),
  deps2state(Identified, Declared, Mods).

deps2state(Identified, Declared, Mods) ->
  #state{ identified_deps = sets:from_list([#load_dep{ from   = M1
                                                     , to     = M2
                                                     , caller = {M2, foo, 0}
                                                     , called = {M1, foo, 0}
                                                     , type   = new
                                                     }
                                            || {M1, M2} <- Identified])
        , declared_deps   = dict:from_list([{Dep, [foo_UP]}
                                            || Dep <- Declared])
        , all_mods        = sets:from_list(Mods)
        }.

-endif.

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
