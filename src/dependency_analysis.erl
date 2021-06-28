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
%%%-------------------------------------------------------------------
%%% File    : dependency_analysis.erl
%%%-------------------------------------------------------------------
%%%==============================================================================
%%%
%%% This is a tool for finding dependencies between modules,
%%% applications and layers. Modules are fetched from all applications.
%%%
%%% This tool reports dependencies that break the invariants from the
%%% file kappa.eterm
%%%
%%% The dependency information is stored in a cache file (`edges_cache_file'). The analysis is
%%% incremental, and only changed modules are reanalyzed.
%%%
%%% Since the analysis starts from beam files, the system has to be
%%% built before it is performed. I've tried to avoid dependencies on
%%% having a running node by doing some ugly filename analysis
%%% to find paths etc.
%%%
%%% @private
-module(dependency_analysis).

-export([ check_apps/2
        , check_kappa_modules/0
        , check_modules/1
        , check_modules/2
        , doit/0
        , make_graph/1
        , make_graph/2
        , make_graph/3
        , report_check_kappa_modules/0
        ]).

-compile({no_auto_import,[error/1, error/2]}).

-include("kappa.hrl").

-type edge() :: #edge{}.

-type edge_filter() :: fun((edge()) -> boolean()).

-type filter() :: apps | mods
                | {apps | mods | only_apps | only_mods, list()}.

-record(warning, { string = []
                 }).

-record(state, { actual_mod2app   = #{} :: #{module() => atom()}
               , api              = ordsets:new() :: ordsets:ordset(tuple())
               , cache_file       = []
               , externals        = []
               , edge_filter      = true_pred() :: edge_filter()
               , warning_filter   = apps        :: filter()
               , graph_outfile    = []
               , kappa_app2layer  = #{} :: #{atom() => atom()}
               , kappa_mod2app    = #{} :: #{module() => atom()}
               , kappa_mod2owner  = []
               , layer_invariants = []
               , layer_order      = []
               , mod_edges        = []
               , fun_edges        = []
               , use_attrs        = false
               , reverse_report   = false
               , report_count     = false
               , warnings         = []
               , ownership        = []
               , hidden           = []
               }).

-type state() :: #state{}.

-record(opts, { reverse_report    = false
              , edge_filter       = true_pred() :: edge_filter()
              , warning_filter    = apps        :: filter()
              , report_count      = false
              , use_attrs         = false
              , type              = all
              }).

-type(opt_list() :: [ {reverse_report, boolean()}
                    | {report_count,   boolean()}
                    | {graph,          boolean()}
                    | {lib_dir,       Path :: string()}
                    | {type,           'layers' | 'api' | 'all'}
                    | (BooleanOpt :: atom()) %% Expands to {BooleanOpt, true}
                    ]).

-type(dependency_type() :: allowed | non_api | layer_break).

-type(dependency_attributes() :: [ non_api
                                 | layer_break
                                 | {count, non_neg_integer()}]).
-define(APPLICATION, kappa).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%==============================================================================
%%
%% Interface
%%

%% Shell script entry point.
report_check_kappa_modules() ->
  report(check_kappa_modules()).

check_kappa_modules() ->
  Funs = analysis_funs(check_kappa),
  State = analyze(Funs, init_state()),
  format_warnings(State).

%% Shell script entry point.
check_modules(Args) ->
  {Opts, Graph, Functions} = make_options(Args),
  State = do_check_modules(Opts),
  maybe_make_graph_from_check(Graph, State, Functions),
  format_warnings(State).

%% Construct an options record from arguments
make_options([Type, Reverse, Count, Entities, Graph, _KredDir,
              Exclusive, Functions, Violations |Names]) ->
  Filter = case Names =:= [] of
             true  -> Entities;
             false ->
               case Exclusive of
                 true  -> {append_atom(only_, Entities), Names};
                 false -> {Entities, Names}
               end
           end,
  EdgeFilter = edge_filter(Violations),
  {DrawGraph, _} = Graph,
  Opts = #opts{ reverse_report = Reverse
              , report_count   = Count
              , edge_filter    = EdgeFilter
              , warning_filter = Filter
              , use_attrs      = DrawGraph
              , type           = Type
              },
  {Opts, Graph, Functions}.

-spec edge_filter(boolean()) -> edge_filter().
edge_filter(Violations) ->
  case Violations of
    false -> fun(_) -> true end;
    true  -> fun(E) -> not edge_is_allowed(E) end
  end.


-spec maybe_make_graph_from_check({boolean(), string()}, #state{}, boolean())
                                 -> ok.
maybe_make_graph_from_check({false, _}, _State, _Functions) -> ok;
maybe_make_graph_from_check({true, File}, #state{warning_filter={mods, Ms}} = S,
                            true) ->
  make_graph({funs_in_mods, Ms}, File, svg, S);
maybe_make_graph_from_check({true, File}, #state{warning_filter=Filter} = S,
                            _Functions) ->
  make_graph(Filter, File, svg, S).

-spec check_apps(atom() | [atom()], opt_list()) -> [string()].

check_apps(Apps, OptList) ->
  check(Apps, apps, OptList).

-spec check_modules(atom() | [atom()], opt_list()) -> [string()].

check_modules(Mods, OptList) ->
  check(Mods, mods, OptList).

check(Names, Entities, OptList) when is_list(OptList) ->
  check(Names, Entities, make_opts(OptList));
check(Name, Entities, Opts) when is_atom(Name)->
  check([Name], Entities, Opts);
check(Names, Entities, #opts{} = Opts) when is_list(Names) ->
  S = do_check_modules(Opts#opts{warning_filter={Entities, Names}}),
  format_warnings(S).

do_check_modules(Opts) ->
  InitState0 = init_state(),
  InitState  = InitState0#state{ warning_filter = Opts#opts.warning_filter
                               , edge_filter    = Opts#opts.edge_filter
                               , reverse_report = Opts#opts.reverse_report
                               , report_count   = Opts#opts.report_count
                               , use_attrs      = Opts#opts.use_attrs
                               },
  analyze(analysis_funs({module_check, Opts#opts.type}), InitState).

doit() ->
  Funs  = analysis_funs(doit),
  State = analyze(Funs, init_state()),
  report(format_warnings(State)).

make_graph(Type) ->
  make_graph(Type, "/tmp/graph.svg").

make_graph(Type, FileName) ->
  make_graph(Type, FileName, svg).

make_graph(Type, FileName, OutputType) ->
  InitState    = init_state(),
  AnalysisFuns = analysis_funs({make_graph, Type}),
  State        = analyze(AnalysisFuns, InitState#state{use_attrs=true}),
  make_graph(Type, FileName, OutputType, State).

make_graph(Type, FileName, OutputType, State) ->
  Edges   = make_graph_edges(State, Type),
  write_graph_file(Edges, FileName, OutputType).

write_graph_file(Edges, FileName, OutputType) ->
  String  = make_graph_string(Edges),
  DotFile = FileName ++ ".dot",
  write_file(DotFile, [String]),
  graphviz:run_dot(DotFile, FileName, OutputType).

make_graph_string(Edges) ->
  graphviz:to_dot("Dependencies", to_dot_edges(strip_self_edges(Edges))).



report("") -> ok;
report(S)  ->
  io:format(standard_error, "~s", [S]),
  error.

%%==============================================================================
%%
%% Top level analysis
%%

analyze(Funs, State) ->
  fold_funs(Funs, State).

fold_funs([Fun|Left], State) ->
  fold_funs(Left, Fun(State));
fold_funs([], State) ->
  State.

analysis_funs(check_kappa) ->
  all_funs();
analysis_funs({make_graph, _}) ->
  all_funs();
analysis_funs(doit) ->
  all_funs();
analysis_funs({module_check, all}) ->
  all_funs();
analysis_funs({module_check, api}) ->
  common_funs() ++
  [ fun find_non_api_calls/1
  ];
analysis_funs({module_check, layers}) ->
  common_funs() ++
  [ fun find_illegal_app_edges/1
  ].

all_funs() ->
  common_funs() ++
    [ fun find_illegal_app_edges/1
    , fun find_non_api_calls/1
    ].

common_funs() ->
  common_funs(kappa_server:architecture_file(),
              kappa_server:ownership_file()).

common_funs(ArchFile, OwnershipFile) ->
  ReadKappaInfo = fun(State) ->
                      read_kappa_info(ArchFile,
                                      OwnershipFile,
                                      State)
                  end,
  [ ReadKappaInfo                %% \ Order is significant between
  , fun find_file_info/1         %% / these two passes. (Externals)
  , fun find_ownership_problems/1
  ].

%%==============================================================================
%%
%% Building the dependency graph
%%

find_file_info(#state{cache_file=CacheFile, hidden=HiddenApps} = State) ->
  LibDirs =
    case os:getenv("ERL_LIBS") of
      false -> code:lib_dir(?APPLICATION);
      Libs -> string:tokens(Libs, ":")
    end,

  Directories0 =
    lists:foldl(fun(LibDir, Acc) ->
                    filelib:wildcard(filename:join([LibDir, "*", "ebin"])) ++ Acc
                end, [], LibDirs),

  Directories =
    lists:filter(fun(D) ->
                     not is_hidden_app(D, HiddenApps)
                 end, Directories0),
  DirMap = abstract_code_analysis:module_dir_map(Directories),
  Reader = fun (Module) ->
               BeamFile = abstract_code_analysis:get_beam_path(Module, DirMap),
               abstract_code_analysis:get_abstract_code(BeamFile)
           end,
  App2Beams = beams_by_app(DirMap),
  AllBeams  = [B || {_, Bs} <- App2Beams, B <- Bs],
  OurBeams  = [B || {A, Bs} <- App2Beams, not ignore_app(A, State), B <- Bs],
  { ModEdges, FunEdges} = find_edges(AllBeams, OurBeams, CacheFile, Reader),
  App2Mods  = [{App, [beam2mod(B) || B <- Bs]} || {App, Bs} <- App2Beams],
  Mod2App   = invert_list_dict(App2Mods),
  State#state{ mod_edges      = ModEdges
             , fun_edges      = FunEdges
             , actual_mod2app = Mod2App
             }.

is_hidden_app(Dir, HiddenApps) ->
  lists:all(
    fun(H) ->
        RE = lists:flatten(io_lib:format(".*/~s/.*", [H])),
        case re:run(Dir, RE) of
          {match, _} -> true;
          _ -> false
        end
    end, HiddenApps).

beam2mod(File) ->
  list_to_atom(filename:basename(filename:rootname(File))).

beams_by_app(DirMap) ->
  lists:foldl(
    fun ({A, B}, D) -> orddict:append(A, B, D) end,
    orddict:new(),
    [begin
       BeamPath = abstract_code_analysis:get_beam_path(M, DirMap),
       {path_to_app(BeamPath), BeamPath}
     end
     || M <- maps:keys(DirMap)]).

path_to_app(BeamPath) ->
  Dir = filename:dirname(BeamPath),
  case filename:basename(Dir) of
    "ebin" -> list_to_atom(filename:basename(filename:dirname(Dir)));
    App -> list_to_atom(App)
  end.

find_edges(AllBeams, OurBeams, CacheFile, ReaderFun) ->
  Cache        = kappa_edge_cache:read_cache_file(CacheFile),
  { CG
  , Attributes
  , Cache1
  , Unchanged} = build_callgraph_and_attributes(AllBeams, ReaderFun, Cache),
  CGModEdges   = create_mod_edges(CG),
  FunEdges     = create_fun_edges(CG),
  _            = dialyzer_callgraph:delete(CG),
  NewCache     = update_cache(Cache1, CGModEdges, FunEdges, Attributes,
                              AllBeams, OurBeams, Unchanged),
  ok           = kappa_edge_cache:cache_to_file(NewCache, CacheFile),
  {NewCache#cache.mod_edges, NewCache#cache.fun_edges}.

build_callgraph_and_attributes(Beams, ReaderFun, Cache) ->
  NewCache = #cache{checksum = Checksums} =
    kappa_edge_cache:pre_check_cache(Beams, Cache),
  StrippedCache = #cache{checksum = Checksums},
  MapFun = fun get_core_and_attrs/2,
  FunState = {ReaderFun, StrippedCache},
  Iterator = iter_init(Beams, MapFun, FunState),
  build_callgraph_and_attributes(Iterator, ReaderFun, dialyzer_callgraph:new(),
                                 0, NewCache, [], []).

get_core_and_attrs(File, {ReaderFun, Cache}) ->
  Module = beam2mod(File),
  AbstractCode = get_abstract_code(Module, ReaderFun, File),
  Checksum = kappa_edge_cache:checksum(AbstractCode),
  case kappa_edge_cache:check_cache(File, Checksum, Cache) of
    ok ->
      skip;
    stale ->
      Attributes = get_attributes_from_abstract_code(Module, AbstractCode),
      Cerl = case abstract_code_analysis:get_core_from_abstract_code(
                    AbstractCode, []) of
               {ok, CE} -> CE;
               error    -> throw({get_core_failed,File})
             end,
      {Checksum, Attributes, Cerl}
  end.

build_callgraph_and_attributes(Iterator, ReaderFun, CG,
                               Label, Cache, Attributes, Unchanged) ->
  case iter_next(Iterator) of
    {{File, skip}, Iterator2} ->
      build_callgraph_and_attributes(Iterator2, ReaderFun, CG,
                                     Label, Cache,
                                     Attributes, [File | Unchanged]);
    {{File, Data}, Iterator2} ->
      {Checksum, ModuleAttributes, Cerl} = Data,
      NewCache = kappa_edge_cache:update_cache(File, Checksum, Cache),
      NewAttributes = ModuleAttributes ++ Attributes,
      {Tree, NextLabel} = cerl_trees:label(cerl:from_records(Cerl), Label),
      {_NewNames, NewEdges} = dialyzer_callgraph:scan_core_tree(Tree, CG),
      dialyzer_callgraph:add_edges(NewEdges, CG),
      build_callgraph_and_attributes(Iterator2, ReaderFun, CG,
                                     NextLabel, NewCache,
                                     NewAttributes, Unchanged);
    empty ->
      {CG, Attributes, Cache, Unchanged}
  end.

get_abstract_code(ModuleName, ReaderFun, File) ->
    case
      ReaderFun(ModuleName) of
      [] ->
        error("failed to read abstract code from ~s. "
              "Compiled it with `debug_info`?", [File]);
      AC -> AC
    end.

get_attributes_from_abstract_code(Mod, AbstractCode) ->
  [{Mod, Type, Value}
   || {attribute, _Line, Type, Values} <- AbstractCode,
      lists:member(Type, [export, load_order, non_upgrade_call]),
      Value <- Values
  ].

create_mod_edges(CG) ->
  create_mod_edges(dict:to_list(dialyzer_callgraph:module_deps(CG)), []).

create_mod_edges([{To, FromList}|Left], Acc) ->
  create_mod_edges(Left, [[{From, To} || From <- FromList]|Acc]);
create_mod_edges([], Acc) ->
  count_edges_and_make_records(lists:flatten(Acc)).

count_edges_and_make_records(Edges) ->
  Ets    = ets:new(foo, []),
  Result = count_edges_and_make_records(Edges, Ets),
  ets:delete(Ets),
  Result.

count_edges_and_make_records([Edge|Left], Ets) ->
  case ets:lookup(Ets, Edge) of
    [] -> ets:insert(Ets, {Edge, 1});
    _  -> ets:update_counter(Ets, Edge, 1)
  end,
  count_edges_and_make_records(Left, Ets);
count_edges_and_make_records([], Ets) ->
  [#edge{from=From, to=To, info=[{count, C}]}
   || {{From, To}, C} <- ets:tab2list(Ets)].

create_fun_edges(CG) ->
  Edges = [[{ lookup_name(From, CG)
            , lookup_name(To, CG)}
            || From <- in_neighbours(To, CG)]
           || To <- dialyzer_callgraph:all_nodes(CG)],
  Edges1 = [{MFAFrom, MFATo}
            || {MFAFrom = {_, _, _},
                MFATo   = {_, _, _}} <- lists:flatten(Edges)],
  count_edges_and_make_records(Edges1).

in_neighbours(X, CG) ->
  case dialyzer_callgraph:in_neighbours(X, CG) of
    none -> [];
    List -> List
  end.

lookup_name({_, _, _} = MFA, _CG) -> MFA;
lookup_name(X, CG)               ->
  case dialyzer_callgraph:lookup_name(X, CG) of
    error -> error;
    {ok, Name} -> Name
  end.

%% =======================
%% Lazy parallel iterator
%%
%% Previous implementation was based on klib_parallel:map/3 and it suffered
%% from it's eagerness: it processed all files at once and then retured a
%% complete list, message-passing it through multiple processes.
%% This, combined with huge nested results size (AST of all KRED modules) lead
%% to high RAM usage (~10Gb).
%% The way new structure works is that it processes tasks in parallel, but
%% keeps only relatively small(!!!) buffer of already processed results.
%% It only feeds workers with new tasks when this buffer is draining.
-record(iter,
        {free = [] :: [pid()],          % workers doing nothing
         busy = 0 :: non_neg_integer(), % workers processing chunk of tasks
         result = [],                   % processed results buffer (not ordered)
         todo = [],                     % not processed tasks
         max_results :: pos_integer(),  % start tasks when len(result) is below
         chunk_size = 10}).

-spec iter_init([file:name_all()],
                fun( (file:name_all(), State) -> Result ),
                State) -> #iter{} when
    State :: any(),
    Result :: any().
iter_init(Beams, MapFun, FunState) ->
  %% Limit Procs to avoid excessive memory growth on many-core machines
  Procs = min(12, max(1, erlang:system_info(schedulers_online) - 1)),
  #iter{
     free = [proc_lib:spawn_link(
                  fun() ->
                      iter_worker_loop(MapFun, FunState)
                  end)
                || _ <- lists:seq(1, Procs)],
     todo = Beams,
     max_results = Procs}.

iter_worker_loop(MapFun, FunState) ->
  receive
    {process, From, Files} ->
      Res = [{File, MapFun(File, FunState)} || File <- Files],
      From ! {result, self(), Res},
      iter_worker_loop(MapFun, FunState);
    Other ->
      exit(Other)
  end.

%% @doc Pull next item from iterator. Order is not guaranteed!
-spec iter_next(#iter{}) -> {any(), #iter{}} | empty.
iter_next(Iter0) ->
  case iter_invariant(iter_recv_all(Iter0)) of
    #iter{result = []} ->
      empty;
    #iter{result = [[Next | LastChunk] | Results]} = Iter ->
      {Next, Iter#iter{result = [LastChunk | Results]}}
  end.

%% The primary goal of this invariant is to always have at least one
%% non-empty #iter.result (as long as there are unprocessed tasks).
%% Secondary goal is to have low RAM footprint from processed results.
%% 3rd goal is low latency of iter_next/1 (so, spend minimum time in
%% blocking receive).
iter_invariant(#iter{result = [[] | Tail]} = I) ->
  %% Drop empty/drained result chunks
  iter_invariant(I#iter{result = Tail});
iter_invariant(#iter{todo = [], free = Free} = I) when Free =/= [] ->
  %% Nothing to do and we have spare workers; kill them
  lists:foreach(fun(Pid) -> Pid ! normal end, Free),
  iter_invariant(I#iter{free = []});
iter_invariant(#iter{todo = Todo0, result = Res, chunk_size = N,
                     max_results = Max,
                     free = [Worker | Free],
                     busy = Busy} = I) when Todo0 =/= [], length(Res) < Max ->
  %% As long as we have:
  %% - tasks to do
  %% - spare workers
  %% - number of "ready results" is smaller than the treshold (currently it
  %%   depends on CPU count)
  %% feed free workers with tasks
  %% Example:
  %% +-----------+-----+-----+-------+------+
  %% |max_results|Free |Busy |Results|Action|
  %% |           |     |     |       |      |
  %% +-----------+-----+-----+-------+------+
  %% |2          |2    |0    |0      |feed  |
  %% +-----------+-----+-----+-------+------+
  %% |2          |1    |1    |0      |feed  |
  %% +-----------+-----+-----+-------+------+
  %% |2          |0    |2    |0      |skip  |
  %% +-----------+-----+-----+-------+------+
  %% |2          |1    |1    |1      |feed  |
  %% +-----------+-----+-----+-------+------+
  %% |2          |0    |2    |1      |skip  |
  %% +-----------+-----+-----+-------+------+
  %% |2          |2    |0    |2      |skip  |
  %% +-----------+-----+-----+-------+------+
  {Chunk, Todo} =
    try lists:split(N, Todo0)
    catch error:badarg ->
        {Todo0, []}
    end,
  Worker ! {process, self(), Chunk},
  iter_invariant(
    iter_recv_all(I#iter{todo = Todo,
                         free = Free,
                         busy = Busy + 1}));
iter_invariant(#iter{result = [], busy = Busy} = I) when Busy =/= 0 ->
  %% We are out of results, but there are still busy workers
  %% Block waiting for result
  receive
    {result, Worker, Res} ->
      iter_invariant(iter_done(I, Worker, Res))
  end;
iter_invariant(I) ->
  %% Nothing to do:
  %% - We still have enough results
  %% - All work is done and all workers are down
  I.

iter_recv_all(I) ->
  receive
    {result, Worker, Res} ->
      iter_recv_all(iter_done(I, Worker, Res))
  after 0 ->
      I
  end.

iter_done(#iter{result = Results, busy = Busy, free = Free} = I, Worker, Res) ->
  I#iter{result = [Res | Results],
         busy = Busy - 1,
         free = [Worker | Free]}.

%%==============================================================================
%%
%% Collect info from the architecture file (kappa.eterm)
%%

read_kappa_info(ArchFile, OwnershipFile, State) ->
  ArchInfo      = kappa:read_architecture_info(ArchFile),
  OwnershipInfo = kappa:get_ownership_info(OwnershipFile),
  build_kappa_info(ArchInfo, OwnershipInfo, State).

-spec build_kappa_info(kappa:architecture_info(),
                       kappa:ownership_info(),
                       state()) -> state().
build_kappa_info(ArchInfo, OwnershipInfo, State) ->
  {ModAppList, ModOwnerList, LayerList, ApiList, Ext, _, _, Hidden} = ArchInfo,
  {Ownership, _} = OwnershipInfo,
  {LayerOrder, LayerInvariants, App2Layer}
            = build_layers(LayerList),
  Mod2App   = build_applications(ModAppList),
  Mod2Owner = build_ownership(ModOwnerList),
  State#state{ kappa_app2layer  = App2Layer
             , kappa_mod2app    = Mod2App
             , kappa_mod2owner  = Mod2Owner
             , layer_order      = LayerOrder
             , layer_invariants = LayerInvariants
             , api              = ordsets:from_list(ApiList)
             , externals        = Ext
             , ownership        = Ownership
             , hidden           = Hidden
             }.

build_layers(LayerList) ->
  Order      = build_layer_order(LayerList),
  Invariants = build_layer_invariants(LayerList),
  Layer2Apps = [{Layer, Apps} || {Layer, Apps, _} <- LayerList],
  App2Layer  = invert_list_dict(Layer2Apps),
  ok         = assert_layer_invariants(Layer2Apps, Invariants),
  {Order, Invariants, App2Layer}.

build_layer_order(List) ->
  build_layer_order(List, 0, []).

build_layer_order([{Layer, _, _}|Left], N, Acc) ->
  build_layer_order(Left, N + 1, [{Layer, N}|Acc]);
build_layer_order([], _N, Acc) ->
  orddict:from_list(Acc).

build_layer_invariants(List) ->
  build_layer_invariants(List, []).

build_layer_invariants([{Layer, _, Legal}|Left], Acc) ->
  build_layer_invariants(Left, [{Layer, ordsets:from_list([Layer|Legal])}|Acc]);
build_layer_invariants([], Acc) ->
  orddict:from_list(Acc).

assert_layer_invariants(Layer2Apps, Invariants) ->
  {AllLayers, Apps} = lists:unzip(Layer2Apps),
  ok                = assert_unique(lists:flatten(Apps), "kappa applications"),
  ok                = assert_unique(AllLayers, "kappa layers"),
  LayerSet          = ordsets:from_list(AllLayers),
  String = [io_lib:format("In allowed calls for ~w "
                          "the unknown layer(s) ~w are listed\n",
                          [Layer, ordsets:subtract(Allowed, LayerSet)])
           || {Layer, Allowed} <- Invariants
            , ordsets:subtract(Allowed, LayerSet) =/= []
            ],
  case String =:= [] of
    true  -> ok;
    false -> error(String)
  end.

build_applications(ModAppList) ->
  {AllMods, _} = lists:unzip(ModAppList),
  ok           = assert_unique(AllMods, "kappa modules"),
  maps:from_list(ModAppList).

build_ownership(ModOwnerList) ->
  {AllMods, _} = lists:unzip(ModOwnerList),
  ok           = assert_unique(AllMods, "kappa modules"),
  orddict:from_list(ModOwnerList).

assert_unique(List, Error) ->
  case List -- ordsets:from_list(List) of
    []   -> ok;
    Dups -> error("Not all ~s are unique! Duplicates: ~p", [Error, Dups])
  end.

%%==============================================================================
%%
%% Analyze the correspondence between the system and kappa
%%

find_ownership_problems(State = #state{ kappa_mod2owner = Mod2Owner
                                      , ownership       = Ownership}) ->
  {_, AllOwners} = lists:unzip(Mod2Owner),
  Owners = [Owner || {Owner, _Props} <- Ownership],
  case ordsets:from_list(AllOwners) -- Owners of
    [] ->
      State;
    UnknownTeams ->
      Warns = [#warning{string = io_lib:format( "~w team is in kappa.eterm " ++
                                                "but not in team.eterm\n"
                                              , [Team])}
               || Team <- UnknownTeams],
      add_warnings(Warns, State)
  end.

%%==============================================================================
%%
%% Analyze the edges
%%

find_illegal_app_edges(State) ->
  Illegal = [Edge || Edge <- State#state.mod_edges,
                     not is_legal_app_edge(Edge, State)],
  Approved = approved_layer_violations(),
  Warns = [#warning{string=io_lib:format("Illegal layer dependency: ~s\n",
                                         [format(Edge, State)])}
           || Edge <- Illegal,
              filter_warnings(edge, Edge, State),
              not edge_is_approved(Edge, Approved)],
  add_warnings(Warns, maybe_add_edge_attr(Illegal, layer_break, State)).

is_legal_app_edge(#edge{from=From, to=To}, State) ->
  mod_can_call(From, To, State).

kappa_mod2app({M, _F, _A}, State) ->
  kappa_mod2app(M, State);
kappa_mod2app(Mod, State = #state{kappa_mod2app=Mod2App}) ->
  case Mod2App of
    #{Mod := App} -> App;
    _ ->
      App = maps:get(Mod, State#state.actual_mod2app),
      error("Module ~p is not listed in ~p.app\n
             or outdated edges_cache_file\n
             or external lib not added to edges_cache_file\n", [Mod, App])
  end.

kappa_mod2layer(Mod, #state{kappa_app2layer=App2Layer} = State) ->
  maps:get(kappa_mod2app(Mod, State), App2Layer).

mod_can_call(From, To, #state{layer_invariants=Invariants} = State) ->
  FromLayer = kappa_mod2layer(From, State),
  ordsets:is_element(kappa_mod2layer(To, State),
                     orddict:fetch(FromLayer, Invariants)).

find_non_api_calls(State) ->
  NonApi = [E || E = #edge{from=From, to=To} <- State#state.mod_edges,
                 not is_api_module(To, State),
                 kappa_mod2app(From, State) =/= kappa_mod2app(To, State)
           ],
  Approved = approved_api_violations(),
  Warns = [#warning{string=io_lib:format("Reference to non-api module: ~s\n",
                                         [format(E, State)])}
           || E <- NonApi,
              filter_warnings(edge, E, State),
              not edge_is_approved(E, Approved)
          ],
  add_warnings(Warns, maybe_add_edge_attr(NonApi, non_api, State)).

approved_api_violations() ->
  approved_violations(approved_api_violations_file).

approved_layer_violations() ->
  approved_violations(approved_layer_violations_file).

approved_violations(Filename) ->
  {ok, Filepath} = application:get_env(?APPLICATION, Filename),
  {ok, Violations} = file:consult(Filepath),
  Violations.

edge_is_approved(E, Approved) ->
  lists:member(edge_to_tuple(E), Approved).

edge_to_tuple(#edge{from = From, to = To}) ->
  {From, To}.

is_api_module(Mod, #state{api=API}) ->
  ordsets:is_element(Mod, API).

%%==============================================================================
%%
%% Graph visualisation
%%

make_graph_edges(State, Type) ->
  Pred  = graph_edge_predicate(Type, State),
  Map   = graph_edge_map_fun(Type, State),
  Edges = join_edge_attributes([Map(E) || E <- State#state.mod_edges
                                            ++ State#state.fun_edges,
                                          Pred(E)]),
  filter_edges(State#state.edge_filter, Edges).

-spec filter_edges(edge_filter(), [edge()]) -> [edge()].
filter_edges(Filter, Edges) ->
  lists:filter(Filter, Edges).


graph_edge_predicate(apps, State)   -> our_mod_pred(State);
graph_edge_predicate(layers, State) -> our_mod_pred(State);
graph_edge_predicate({mods, ModList}, #state{reverse_report=Rev}) ->
  fun(#edge{from=X, to=Y}) -> ((lists:member(X, ModList) andalso not Rev)
                               orelse
                               (lists:member(Y, ModList) andalso Rev))
  end;
graph_edge_predicate({only_mods, ModList}, _State) ->
  fun(#edge{from=X, to=Y}) -> (lists:member(X, ModList) andalso
                               lists:member(Y, ModList))
  end;
graph_edge_predicate({apps, AppList}, State = #state{reverse_report=Rev}) ->
  fun(#edge{from=X, to=Y}) ->
      ((lists:member(kappa_mod2app(X, State), AppList) andalso not Rev)
       orelse
       (lists:member(kappa_mod2app(Y, State), AppList) andalso Rev))
  end;
graph_edge_predicate({only_apps, AppList}, State) ->
  fun(#edge{from=X, to=Y}) ->
        (lists:member(kappa_mod2app(X, State), AppList)
         andalso lists:member(kappa_mod2app(Y, State), AppList))
  end;
graph_edge_predicate({apps_in_layer, Layer}, State) ->
  AtomLayer = list_to_atom(Layer),
  fun(#edge{from=From, to=To}) ->
      kappa_mod2layer(From, State) =:= AtomLayer andalso
        kappa_mod2layer(To, State) =:= AtomLayer
  end;
graph_edge_predicate({funs_in_mods, ModList}, _State) ->
  fun(#edge{from={X, _, _}, to={Y, _, _}}) ->
      lists:member(X, ModList) andalso lists:member(Y, ModList);
     (#edge{}) ->
      false
  end.

our_mod_pred(State) ->
  fun(#edge{from = {X, _, _}, to = {Y, _, _}}) ->
      not (ignore_mod(X, State) orelse ignore_mod(Y, State));
     (#edge{}) ->
      %% Module edges are already filtered to our mods
      true
  end.

true_pred() ->
  fun(_) -> true end.

graph_edge_map_fun({mods, _}, _State) ->
  fun(E) -> E end;
graph_edge_map_fun({only_mods, _}, _State) ->
  fun(E) -> E end;
graph_edge_map_fun(apps, State) ->
  fun(#edge{} = E) -> E#edge{ from = kappa_mod2app(E#edge.from, State)
                            , to   = kappa_mod2app(E#edge.to  , State)
                            }
  end;
graph_edge_map_fun({only_apps, _}, State) ->
  fun(#edge{} = E) -> E#edge{ from = kappa_mod2app(E#edge.from, State)
                            , to   = kappa_mod2app(E#edge.to  , State)
                            }
  end;
graph_edge_map_fun({apps, _}, State) ->
  fun(#edge{} = E) -> E#edge{ from = kappa_mod2app(E#edge.from, State)
                            , to   = kappa_mod2app(E#edge.to  , State)
                            }
  end;
graph_edge_map_fun(layers, State) ->
  fun(#edge{} = E) -> E#edge{ from = kappa_mod2layer(E#edge.from, State)
                            , to   = kappa_mod2layer(E#edge.to  , State)
                            }
  end;
graph_edge_map_fun({apps_in_layer, _}, State) ->
  graph_edge_map_fun(apps, State);
graph_edge_map_fun({funs_in_mods, _}, _State) ->
  fun(E) -> E end.

join_edge_attributes(Edges) ->
  Fun = fun(E, AccDict) ->
            Stripped = E#edge{info=[]},
            NewInfo = join_edge_attributes(E, dict:find(Stripped, AccDict)),
            dict:store(Stripped, NewInfo, AccDict)
        end,
  EdgeDict = lists:foldl(Fun, dict:new(), Edges),
  [E#edge{info=Attrs} || {E, Attrs} <- dict:to_list(EdgeDict)].

join_edge_attributes(#edge{info=I1}, {ok, I2}) -> join_edge_info(I1, I2);
join_edge_attributes(#edge{info=I1}, error   ) -> I1.

%% Transform a list of internal edges to a list of edges suitable for
%% sending to dot.
to_dot_edges(Edges) ->
  F = fun(#edge{from = From, to = To, info = Info}) ->
          {format_node(From), format_node(To), dot_edge_attrs(Info)}
      end,
  lists:map(F, Edges).

%% Format node name for nicer visual appeal.
format_node({M,F,A}) ->
  lists:flatten(io_lib:format("~w:~w/~w", [M, F, A]));
format_node(T) -> T.

-spec dot_edge_attrs(dependency_attributes()) -> [{color, atom()} |
                                                  {label, string()}].
dot_edge_attrs(Info) ->
  New    = dot_attributes(),
  Colour = edge_dependency_colour(edge_dependency_type(Info)),
  Attributes = dot_attributes_set(color, Colour, New),
  Count  = edge_dependency_count(Info),
  dot_attributes_set(label, integer_to_list(Count), Attributes).

%% Handling of dot edge attributes
dot_attributes() -> [].

dot_attributes_set(Key, Value, Attributes) ->
  lists:keystore(Key, 1, Attributes, {Key, Value}).

%% Determine type of dependency from list of attributes
-spec edge_dependency_type(dependency_attributes()) -> dependency_type().
edge_dependency_type(Attrs) ->
  C = fun(layer_break, _)   -> layer_break;
         (non_api, allowed) -> non_api;
         (_, T) -> T
      end,
  lists:foldl(C, allowed, Attrs).

edge_is_allowed(#edge{info = Info}) ->
  edge_dependency_type(Info) == allowed.

edge_dependency_count(Attrs) ->
  {_, Value} = lists:keyfind(count, 1, Attrs),
  Value.

-spec edge_dependency_colour(dependency_type()) -> atom().
edge_dependency_colour(layer_break) -> red;
edge_dependency_colour(non_api)     -> orange;
edge_dependency_colour(allowed)     -> green.

strip_self_edges(Edges) ->
  [E || E = #edge{from=X, to=Y} <- Edges, X =/= Y].

%%==============================================================================
%%
%% Utils
%%

make_opts(List) ->
  make_opts(List, #opts{}).

make_opts([{reverse_report, Val}|Left], Opts) when is_boolean(Val) ->
  make_opts(Left, Opts#opts{reverse_report=Val});
make_opts([{report_count, Val}|Left], Opts) when is_boolean(Val) ->
  make_opts(Left, Opts#opts{report_count=Val});
make_opts([{graph, Val}|Left], Opts) when is_boolean(Val) ->
  make_opts(Left, Opts#opts{use_attrs=Val});
make_opts([{type, Val}|Left], Opts) when is_atom(Val) ->
  make_opts(Left, Opts#opts{type=Val});
make_opts([Opt|Left], Opts) when is_atom(Opt) ->
  make_opts([{Opt, true}|Left], Opts);
make_opts([], Opts) ->
  Opts.

ignore_app(App, #state{externals=Externals}) ->
  lists:member(list_to_atom(filename:basename(App)), Externals).

ignore_mod(Mod, #state{actual_mod2app = Mod2App} = State) ->
  ignore_app(maps:get(Mod, Mod2App), State).

invert_list_dict(Dict) ->
  List    = [{Y, X} || {X, Ys} <- Dict, Y <- Ys],
  InvDict = maps:from_list(List),
  case map_size(InvDict) =:= length(List) of
    true -> ok;
    false ->
      %% found duplicates in List
      DupDict =
        lists:foldl(
          fun({Module,_App}, D) ->
              dict:update_counter(Module, 1, D)
          end, dict:new(), List),
      DupMods = [Mod || {Mod,N} <- dict:to_list(DupDict), N > 1],
      erlang:error({duplicate_modules_found, DupMods})
  end,
  InvDict.

-spec error(string()) -> no_return().
error(String) ->
  error(String, []).

-spec error(string(), [any()]) -> no_return().
error(Format, Data) ->
  erlang:error(fmt(Format, Data)).

format(#edge{from=From, to=To}, State) ->
  io_lib:format("~w (~w) -> ~w (~w)", [ From, kappa_mod2app(From, State)
                                      , To,   kappa_mod2app(To, State)]).

fmt(Format, Data) ->
  lists:flatten(io_lib:format(Format, Data)).

add_warnings(Warns, State) ->
  State#state{warnings=lists:flatten([Warns|State#state.warnings])}.

%% NOTE: It is important that the affected edges is a subset of the
%% current edges. That is, all edges must compare equal to one edge
%% in mod_edges.
maybe_add_edge_attr(_Edges, _Attr, State = #state{use_attrs=false}) -> State;
maybe_add_edge_attr(AttrEdges, Attr, State = #state{mod_edges=Edges}) ->
  NewEdges = add_edge_attr(lists:sort(AttrEdges), lists:sort(Edges), Attr),
  State#state{mod_edges=NewEdges}.

add_edge_attr([Edge|Left1], [Edge|Left2], Attr) ->
  [ Edge#edge{info=join_edge_info(Edge#edge.info, [Attr])}
  | add_edge_attr(Left1, Left2, Attr)];
add_edge_attr([], Edges, _Attr) ->
  Edges;
add_edge_attr(Edges1, [Edge|Left2], Attr) ->
  [Edge|add_edge_attr(Edges1, Left2, Attr)].

join_edge_info([{Tag, X}|Xs], [{Tag, Y}|Ys])    ->
  [join_edge_info_post(Tag, X, Y) | join_edge_info(Xs, Ys)];
join_edge_info([X|Xs], [Y|Ys])     when X =:= Y -> [X|join_edge_info(Xs, Ys)];
join_edge_info([X|Xs], [Y|_] = Ys) when X =<  Y -> [X|join_edge_info(Xs, Ys)];
join_edge_info([X|_] = Xs, [Y|Ys]) when X >   Y -> [Y|join_edge_info(Xs, Ys)];
join_edge_info([]    , Ys)                      -> Ys;
join_edge_info(Xs    , [])                      -> Xs.

join_edge_info_post(count, X, Y) -> {count, X + Y};
join_edge_info_post(_, X, X) -> X.

filter_warnings(edge, #edge{from=From, to=To}, #state{} = S) ->
  X = case S#state.reverse_report of
        true  -> To;
        false -> From
      end,
  case S#state.warning_filter of
    apps               -> true;
    mods               -> true;
    {apps     , Apps} -> lists:member(kappa_mod2app(X, S), Apps);
    {mods     , Mods} -> lists:member(X, Mods);
    {only_apps, Apps} -> lists:member(kappa_mod2app(From, S), Apps) andalso
                           lists:member(kappa_mod2app(To, S), Apps);
    {only_mods, Mods} -> lists:member(From, Mods) andalso
                           lists:member(To, Mods)
  end.

cache_file() ->
  application:get_env(?APPLICATION, edges_cache_file, "kappa.edges").

format_warnings(#state{report_count=true, warnings=Warnings}) ->
  [integer_to_list(length(lists:flatten(Warnings))) ++ "\n"];
format_warnings(#state{warnings=Warnings}) ->
  [S || #warning{string=S} <- lists:flatten(Warnings)].


init_state() ->
  #state{cache_file = cache_file()}.

append_atom(A1, A2) ->
  list_to_atom(atom_to_list(A1) ++ atom_to_list(A2)).

%%==============================================================================
%%
%% Handling the file cache.
%%

update_cache(Cache, CGEdges, FunEdges, NewAttributes,
             AllBeams, OurBeams, Unchanged) ->
  AllBeamSet   = sets:from_list(AllBeams),
  AllMods      = sets:from_list([beam2mod(B) || B <- AllBeams]),
  OurMods      = sets:from_list([beam2mod(B) || B <- OurBeams]),
  UnchangedSet = sets:from_list([beam2mod(B) || B <- Unchanged]),
  %% The edges need only contain edges between modules owned by us
  OldEdges     = [Edge || Edge = #edge{from=From} <- Cache#cache.mod_edges
                        , sets:is_element(From, UnchangedSet)],
  NewEdges     = [Edge || Edge = #edge{from=From, to=To} <- CGEdges
                        , sets:is_element(From, OurMods)
                        , sets:is_element(To, OurMods)],
  %% Fun edges on the other hand are needed from all modules, not just
  %% those owned by us
  OldFunEdges  = [Edge || Edge = #edge{from={From,_,_}} <- Cache#cache.fun_edges
                        , sets:is_element(From, UnchangedSet)],
  NewFunEdges  = [Edge || Edge = #edge{from={From,_,_}, to={To,_,_}} <- FunEdges
                        , sets:is_element(From, AllMods)
                        , sets:is_element(To, AllMods)],
  %% Separate export, load order and non-upgrade call attributes
  OldExports   = [Export || Export = {M,_,_} <- Cache#cache.exports
                          , sets:is_element(M, UnchangedSet)],
  NewExports   = [{Mod, Fun, Arity}
                  || {Mod, export, {Fun, Arity}} <- NewAttributes],
  OldLoadOrds  = [LoadOrd || LoadOrd = {M,_} <- Cache#cache.load_orders
                           , sets:is_element(M, UnchangedSet)],
  NewLoadOrds  = [{Mod, Val} || {Mod, load_order, Val} <- NewAttributes],
  OldNonCalls  = [NonCall || NonCall = {M,_} <- Cache#cache.non_upgrade_calls
                           , sets:is_element(M, UnchangedSet)],
  NewNonCalls  = [{Mod, Val} || {Mod, non_upgrade_call, Val} <- NewAttributes],
  NewChecksum  = orddict:filter(fun(F, _) -> sets:is_element(F, AllBeamSet) end,
                                Cache#cache.checksum),
  #cache{ mod_edges         = NewEdges ++ OldEdges
        , fun_edges         = OldFunEdges ++ NewFunEdges
        , exports           = OldExports ++ NewExports
        , load_orders       = OldLoadOrds ++ NewLoadOrds
        , non_upgrade_calls = OldNonCalls ++ NewNonCalls
        , checksum          = NewChecksum
        }.


write_file(File, Payload) ->
  case file:write_file(File, Payload) of
    ok              -> ok;
    {error, Reason} -> erlang:error({write_error, {File, Reason}})
  end.


%% Internal tests needed since the external interface is not easily
%% testable (yet).
-ifdef(TEST).

render_simple_node_test() ->
  ?assertEqual(foo, format_node(foo)).

render_mfa_node_test() ->
  ?assertEqual("frobozz:magic/42", format_node({frobozz, magic, 42})).

%% Test rendering of attributes to correct dot attributes
render_attributes_test_() ->
  [?_test(test_dot_attributes([non_api, {count, 1}], orange, "1")),
   ?_test(test_dot_attributes([{count, 4}], green, "4")),
   ?_test(test_dot_attributes([layer_break, {count, 2}], red, "2")),
   ?_test(test_dot_attributes([layer_break, non_api, {count, 3}],
                              red, "3"))
  ].

%% Test that "worst" dependency is returned
edge_dependency_test_() ->
  [
   %% The type of dependency is allowed in the absence of atoms
   %% non_api and layer_break.
   ?_assertEqual(allowed,     edge_dependency_type([])),
   ?_assertEqual(allowed,     edge_dependency_type([{count, 2}])),

   %% Dependency is non_api if it contains the atom non_api, but not
   %% the atom layer_break.
   ?_assertEqual(non_api,     edge_dependency_type([non_api])),
   ?_assertEqual(non_api,     edge_dependency_type([non_api, {count, 3}])),
   ?_assertEqual(non_api,     edge_dependency_type([{count, 3}, non_api])),

   %% Dependency is layer_break break if it contains the atom
   %% layer_break and possibly non_api.
   ?_assertEqual(layer_break, edge_dependency_type([layer_break])),
   ?_assertEqual(layer_break, edge_dependency_type([layer_break,
                                                    non_api])),
   ?_assertEqual(layer_break, edge_dependency_type([non_api,
                                                    layer_break])),
   ?_assertEqual(layer_break, edge_dependency_type([non_api,
                                                    {count, 4},
                                                    layer_break]))
  ].


%% Test rendering of full edges
render_edge_test_() ->
  [?_test(test_render_edge(make_edge({foo, bar, 3}, zap, [layer_break]),
                           "foo:bar/3", zap, red, "1")),
   ?_test(test_render_edge(make_edge(zip, zap, [{count, 2}]),
                           zip, zap, green, "2")),
   ?_test(test_render_edge(make_edge(zip, {zap, foo, 7},
                                     [{count, 4}, non_api]),
                           zip, "zap:foo/7", orange, "4"))

   ].

%% Test rendering of several edges to preserve number of edges
%% Rendering of indivudal edges, nodes and attributes taken care
%% elsewhere
render_length_test_() ->
  [?_test(test_render_length([], 0)),
   ?_test(test_render_length([make_edge(n0, n1)], 1)),
   ?_test(test_render_length([make_edge(n0, n1),
                              make_edge(n0, n2)], 2)),
   ?_test(test_render_length([make_edge(n0, n1),
                              make_edge(n0, n2),
                              make_edge(n1, n3),
                              make_edge(n2, n3)], 4))
   ].


%% Edges can be either module to module or function to function so
%% when mapping a node to an application, we must be able to handle
%% both types of nodes, i.e., a simple module or {Module, Function,
%% Arity}.
module_node_to_app_test() ->
  Mod2App = maps:from_list([{noodle, appendix}]),
  State = #state{kappa_mod2app = Mod2App},
  ?assertEqual(appendix, kappa_mod2app(noodle, State)).

mfa_node_to_app_test() ->
  Mod2App = maps:from_list([{noodle, appendix}]),
  State = #state{kappa_mod2app = Mod2App},
  ?assertEqual(appendix, kappa_mod2app({noodle, poodle, 2}, State)).



%% Default values of arguments
-record(cmdargs, { type       = all
                 , reverse    = false
                 , count      = false
                 , entities   = mods
                 , graph      = {false, ""}
                 , rootdir    = "."
                 , exclusive  = false
                 , functions  = false
                 , violations = false
                 , names      = []
                 }).

make_arg_list(#cmdargs{ type       = Type
                      , reverse    = Reverse
                      , count      = Count
                      , entities   = Entities
                      , graph      = Graph
                      , rootdir    = Dir
                      , exclusive  = Exclusive
                      , functions  = Functions
                      , violations = Violations
                      , names      = Names}) ->
  [Type, Reverse, Count, Entities, Graph, Dir, Exclusive, Functions,
   Violations |Names].

%% Test that we install the correct edge filter from the argument list
%% Default is to filter out nothing
edge_filter_default_test() ->
  EdgeFilter = edge_filter_from_cmdargs(#cmdargs{}),
  Edges      = [make_edge(foo, bar, [non_api]),
                make_edge(bar, baz, [layer_break]),
                make_edge(baz, zap, []),
                make_edge(zap, foo, [non_api, layer_break])],
  ?assertEqual(Edges, filter_edges(EdgeFilter, Edges)).

%% With violations set to false, we should keep all edges
edge_filter_false_test() ->
  EdgeFilter = edge_filter_from_cmdargs(#cmdargs{violations = false}),
  Edges      = [make_edge(foo, bar, [non_api]),
                make_edge(bar, baz, [layer_break]),
                make_edge(baz, zap, []),
                make_edge(zap, foo, [non_api, layer_break])],
  ?assertEqual(Edges, filter_edges(EdgeFilter, Edges)).

%% With violations set to true, we should only keep edges that are
%% violations.
edge_filter_true_test() ->
  EdgeFilter = edge_filter_from_cmdargs(#cmdargs{violations = true}),
  ValidEdge  = make_edge(baz, zap, []),
  Edges      = [make_edge(foo, bar, [non_api]),
                make_edge(bar, baz, [layer_break]),
                ValidEdge,
                make_edge(zap, foo, [non_api, layer_break])],
  Filtered   = filter_edges(EdgeFilter, Edges),
  Expected   = Edges -- [ValidEdge],
  ?assertEqual(Expected, Filtered).


%% Test helpers
edge_filter_from_cmdargs(CmdArgs) ->
  {Opts, _, _} = make_options(make_arg_list(CmdArgs)),
  Opts#opts.edge_filter.

dot_attributes_get(Key, Attributes) ->
  {Key, Value} = lists:keyfind(Key, 1, Attributes),
  Value.

test_render_edge(Edge, From, To, Color, Label) ->
  {FromRendered, ToRendered, Attributes} = render_edge(Edge),
  ?assertEqual(From, FromRendered),
  ?assertEqual(To, ToRendered),
  ?assertEqual(Color, dot_attributes_get(color, Attributes)),
  ?assertEqual(Label, dot_attributes_get(label, Attributes)).

test_render_length(L, ExpectedLength) ->
  RenderedEdges = to_dot_edges(L),
  ?assertEqual(ExpectedLength, length(RenderedEdges)).

test_dot_attributes(Properties, ExpectedColor, ExpectedLabel) ->
  Attributes = dot_edge_attrs(Properties),
  ?assertEqual(ExpectedColor, dot_attributes_get(color, Attributes)),
  ?assertEqual(ExpectedLabel, dot_attributes_get(label, Attributes)).

render_edge(Edge) ->
  DotEdges = to_dot_edges([Edge]),
  ?assertEqual(1, length(DotEdges)),
  hd(DotEdges).

make_edge(From, To) ->
  make_edge(From, To, []).

make_edge(From, To, Attributes) ->
  %% Always include a count attribute
  Attrs = case lists:keyfind(count, 1, Attributes) of
            false -> lists:keystore(count, 1, Attributes, {count, 1});
            _ -> Attributes
          end,
  #edge{from = From, to = To, info = Attrs}.

-endif.

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
