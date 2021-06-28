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
%%% @doc Klarna Application Analytics Server.
%%%
%%% It holds a caches of architecture specification files as well as call graph edges.
%% @private
-module(kappa_server).
-behaviour(gen_server).

%%%_* Exports ==========================================================
%% API
-export([ architecture_file/0
        , db_ownership_file/0
        , get_assets/1
        , get_assets/2
        , get_layer/1
        , get_mutes/0
        , get_owner/1
        , get_owners/0
        , get_properties/1
        , get_table_owner/1
        , ownership_file/0
        , refresh/0
        , start/1
        , start/3
        ]).

%% Callbacks
-export([ code_change/3
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , init/1
        , start_link/0
        , terminate/2
        ]).

-type table_ownership_rules() :: [{subject(), kappa:owner()}].
-type regexp()          :: string().
-type subject()         :: kappa:table() | regexp().

%%%_* Defines ==========================================================
-define(SERVER, ?MODULE).
-define(APPLICATION, kappa).

%%%_* Record ===========================================================
-record(cache, { mod2apps     = []
               , mod2owner    = []
               , layer2apps   = []
               , apis         = []
               , externals    = []
               , ownership    = []
               , db_ownership = []
               , mute_apps    = []
               , app2owner    = []
               }).
-record(state, { blueprint_cts     = undefined %% Cache Timestamp
               , ownership_cts     = undefined
               , db_ownership_cts  = undefined
               , cache             = #cache{}
               , error_logger      = application:get_env(?APPLICATION, error_logger,
                                                         fun error_logger:error_msg/2)
               , architecture_file = architecture_file()
               , ownership_file    = ownership_file()
               , db_ownership_file = db_ownership_file()
               }).

%%%_* Code =============================================================
%%%_* API --------------------------------------------------------------
start(ErrorLoggerFun) ->
  gen_server:start({local, ?SERVER}, ?MODULE,
                   [{error_logger, ErrorLoggerFun}], []).

start(ErrorLoggerFun, ArchitectureFile, OwnershipFile) ->
  gen_server:start({local, ?SERVER}, ?MODULE,
                   [  {error_logger, ErrorLoggerFun}
                    , {architecture_file, ArchitectureFile}
                    , {ownership_file, OwnershipFile}], []).


refresh() ->
  gen_server:cast(?SERVER, update_cache).

get_layer(Name) ->
  gen_server:call(?SERVER, {get_layer, Name}).

get_mutes() ->
  gen_server:call(?SERVER, {get_mutes}).

get_owner(Module) ->
  gen_server:call(?SERVER, {get_owner, Module}).

get_owners() ->
  gen_server:call(?SERVER, {get_owners}).

get_properties(Owner) ->
  gen_server:call(?SERVER, {get_properties, Owner}).

get_table_owner(Table) ->
  gen_server:call(?SERVER, {get_table_owner, Table}).

get_assets(Owner) ->
  gen_server:call(?SERVER, {get_assets, Owner, modules}).

get_assets(Owner, Type) ->
  gen_server:call(?SERVER, {get_assets, Owner, Type}).

%% Default files for architecture and ownership
architecture_file() ->
  application:get_env(?APPLICATION, architecture_file, "kappa.eterm").

ownership_file() ->
  application:get_env(?APPLICATION, ownership_file, "team.eterm").

db_ownership_file() ->
  application:get_env(?APPLICATION, db_ownership_file, "tables.eterm").

%%%_* Callbacks --------------------------------------------------------
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% init([]) ->
%%   {ok, update_cache(#state{})};
%% init(ErrorLoggerFun) ->
%%   {ok, update_cache(#state{error_logger=ErrorLoggerFun})}.

init(Opts) ->
  {ok, update_cache(init_state(Opts))}.

init_state(Opts) ->
  lists:foldl(fun init_state/2, #state{}, Opts).

init_state({error_logger, Logger}, State) ->
  State#state{error_logger = Logger};
init_state({architecture_file, FileName}, State) ->
  State#state{architecture_file = FileName};
init_state({ownership_file, FileName}, State) ->
  State#state{ownership_file = FileName};
init_state({db_ownership_file, FileName}, State) ->
  State#state{db_ownership_file = FileName}.

handle_call(Request, From, OldState) when not is_record(OldState, state) ->
  handle_call(Request, From, update_state(OldState));
handle_call({get_layer, Name}, _From, State0) ->
  State     = ensure_cached(State0),
  Layers    = (State#state.cache)#cache.layer2apps,
  Mod2App   = (State#state.cache)#cache.mod2apps,
  %% If Name is a module, we find the application it belongs to.
  App        = case kf(Name, Mod2App, undefined) of
                  undefined -> Name;
                  Application -> Application
                end,
  Layer     = get_application_layer(Layers, App),
  {reply, Layer, State};
handle_call({get_owner, Module}, _From, State0) ->
  State = ensure_cached(State0),
  Owner = i_get_owner(Module, State),
  {reply, Owner, State};
handle_call({get_properties, Owner}, _From, State0) ->
  State      = ensure_cached(State0),
  Ownership  = (State#state.cache)#cache.ownership,
  Properties = kf(Owner, Ownership, []),
  {reply, Properties, State};
handle_call({get_table_owner, Table}, _From, State0) ->
  State = ensure_cached(State0),
  Reply = get_table_owner(Table, State),
  {reply, Reply, State};
handle_call({get_owners}, _From, State0) ->
  State      = ensure_cached(State0),
  Ownership  = (State#state.cache)#cache.ownership,
  Owners     = [Owner || {Owner, _Props} <- Ownership],
  {reply, Owners, State};
handle_call({get_mutes}, _From, State0) ->
  State = ensure_cached(State0),
  Mutes = (State#state.cache)#cache.mute_apps,
  AddOwner = fun(App) -> {i_get_owner(App, State), App} end,
  {reply, lists:sort(lists:map(AddOwner, Mutes)), State};
handle_call({get_assets, Owner, modules}, _From, State0) ->
  State     = ensure_cached(State0),
  Mod2Owner = (State#state.cache)#cache.mod2owner,
  Modules   = [Module || {Module, O} <- Mod2Owner, Owner =:= O],
  {reply, Modules, State};
handle_call({get_assets, Owner, apps}, _From, State0) ->
  State     = ensure_cached(State0),
  Mod2Apps  = (State#state.cache)#cache.mod2apps,
  Mod2Owner = (State#state.cache)#cache.mod2owner,
  Modules   = [Module || {Module, O} <- Mod2Owner, Owner =:= O],
  Apps      = lists:foldl(fun(M, Apps) ->
                              App = kf(M, Mod2Apps, x),
                              ordsets:add_element(App, Apps)
                          end,
                          [],
                          Modules),
  {reply, Apps, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast(Msg, OldState) when not is_record(OldState, state) ->
  handle_cast(Msg, update_state(OldState));
handle_cast(update_cache, State) ->
  {noreply, update_cache(State)};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(Info, OldState) when not is_record(OldState, state) ->
  handle_info(Info, update_state(OldState));
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%_* Internals --------------------------------------------------------
i_get_owner(Module, State) ->
  Mod2Owner = (State#state.cache)#cache.mod2owner,
  case kf(Module, Mod2Owner, undefined) of
    undefined ->
      App2Owner = (State#state.cache)#cache.app2owner,
      kf(Module, App2Owner, undefined);
    Owner -> Owner
  end.

get_table_owner(Table, State) ->
  try
    Ownership = (State#state.cache)#cache.db_ownership,
    do_get_table_owner(Table, Ownership)
  catch
    Class:Reason ->
      ErrorLoggerFun = State#state.error_logger,
      ErrorLoggerFun("~p(~p): Getting table owner failed: ~p:~p~n",
                     [?MODULE, ?LINE, Class, Reason]),
      undefined
  end.

%% @doc Get the owner (according to Kappa) of a specified table
-spec do_get_table_owner(kappa:table(), table_ownership_rules()) -> kappa:owner().
do_get_table_owner(Table, DBOwnership) ->
  {OwnedTables, Regexps} = parse_ownership(DBOwnership),
  case lists:keyfind(Table, 1, OwnedTables) of
    {Table, Owner} -> Owner;
    false          -> find_regexp_owner(Table, Regexps)
  end.

parse_ownership(DBOwnership) ->
  F = fun({Table, _Owner} = Ownership, {Tables, Regexps}) ->
          if is_atom(Table) -> {[Ownership|Tables], Regexps};
             is_list(Table) -> {Tables, [Ownership|Regexps]};
             true           -> throw({error, bad_ownership})
          end
      end,
  lists:foldl(F, {[], []}, DBOwnership).
find_regexp_owner(Table, Regexps) ->
  case find_matching_regexp(atom_to_list(Table), Regexps) of
    {ok, {_Regexp, Owner}} -> Owner;
    false                  -> undefined
  end.

find_matching_regexp(_String, [])     -> false;
find_matching_regexp(String, [{Regexp, Owner}|Regexps]) ->
  case re:run(String, Regexp) of
    {match, _} -> {ok, {Regexp, Owner}};
    _Otherwise -> find_matching_regexp(String, Regexps)
  end.

%% @doc We have to ensure that we access the file system as seldom as possible.
ensure_cached(State=#state{blueprint_cts=undefined})    -> update_cache(State);
ensure_cached(State=#state{ownership_cts=undefined})    -> update_cache(State);
ensure_cached(State=#state{db_ownership_cts=undefined}) -> update_cache(State);
ensure_cached(State)                                    -> State.

%% @doc Update the KAPPA architecture and ownership cache. Return the old cache
%% state if updating fails.
update_cache(State) ->
  try
    ArchFile        = State#state.architecture_file,
    OwnershipFile   = State#state.ownership_file,
    DBOwnershipFile = State#state.db_ownership_file,

    {Blueprint, TimeRef1}   = kappa:get_architecture_info(ArchFile),
    {Ownership, TimeRef2}   = kappa:get_ownership_info(OwnershipFile),
    {DBOwnership, TimeRef3} = kappa:get_db_ownership_info(DBOwnershipFile),

    {Mod2Apps, Mod2Owner, Layer2Apps, APIs, Externals, MuteApps, App2Owner, _Hidden} =
      kappa:collect_architecture_info(Blueprint),
    Cache = #cache{ mod2apps     = Mod2Apps
                  , mod2owner    = Mod2Owner
                  , layer2apps   = Layer2Apps
                  , apis         = APIs
                  , externals    = Externals
                  , ownership    = Ownership
                  , mute_apps    = MuteApps
                  , app2owner    = App2Owner
                  , db_ownership = DBOwnership
                  },
    State#state{ blueprint_cts    = TimeRef1
               , ownership_cts    = TimeRef2
               , db_ownership_cts = TimeRef3
               , cache            = Cache
               }
  catch
    _C:R ->
      ErrorLoggerFun = State#state.error_logger,
      ErrorLoggerFun("~p(~p): Updating KAPPA cache failed: ~p~n",
                     [?MODULE, ?LINE, R]),
      State
  end.

kf(Key, List, Default) ->
  case lists:keyfind(Key, 1, List) of
    {Key, Value} -> Value;
    false        -> Default
  end.

get_application_layer([{Layer, Apps, AllowedLayers}|T], App) ->
  case lists:member(App, Apps) of
    true  -> {Layer, AllowedLayers};
    false -> get_application_layer(T, App)
  end;
get_application_layer([], _App)                              ->
  undefined.

update_state({state, BlueprintCts, OwnershipCts, Cache, ErrorLogger,
              ArchitectureFile, OwnershipFile}) ->
  #state{ blueprint_cts     = BlueprintCts
        , ownership_cts     = OwnershipCts
        , db_ownership_cts  = undefined
        , cache             = update_cache_record(Cache)
        , error_logger      = ErrorLogger
        , architecture_file = ArchitectureFile
        , ownership_file    = OwnershipFile
        , db_ownership_file = db_ownership_file()
        }.

update_cache_record({cache, Mod2Apps, Mod2Owner, Layer2Apps, Apis, Externals,
                     Ownership, MuteApps, App2Owner}) ->
  #cache{ mod2apps     = Mod2Apps
        , mod2owner    = Mod2Owner
        , layer2apps   = Layer2Apps
        , apis         = Apis
        , externals    = Externals
        , ownership    = Ownership
        , db_ownership = []
        , mute_apps    = MuteApps
        , app2owner    = App2Owner
        }.


%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
