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
%%% @doc Functions to handle kappa.edges cache files.
-module(kappa_edge_cache).

%% API
-export([ read_cache_file/1
        , cache_to_file/2
        , pre_check_cache/2
        , checksum/1
        , check_cache/3
        , update_cache/3
        ]).

%%% Includes ===========================================================

-include("kappa.hrl").

%%% Definitions ========================================================

-define(cache_format_version, 2).
%% The first version of the cache file did not contain any version
%% number. So the first actual version number one may encounter in a
%% file is 2.

%%% API ================================================================

read_cache_file(FileName) ->
  case file:consult(FileName) of
    {ok, [ ?cache_format_version
         , ModEdges
         , FunEdges
         , Exports
         , LoadOrders
         , NonUpgradeCalls
         , Checksum
         ]} ->
      #cache{ mod_edges         = ModEdges
            , fun_edges         = FunEdges
            , exports           = Exports
            , load_orders       = LoadOrders
            , non_upgrade_calls = NonUpgradeCalls
            , checksum          = Checksum
            };
    _ ->
      #cache{}
  end.

cache_to_file(Cache, CacheFile) ->
  String = [io_lib:format("\n%%% ~s\n~200p.\n", [Field, Value])
            || {Field, Value} <-
                 [ {version,           ?cache_format_version}
                 , {mod_edges,         lists:sort(Cache#cache.mod_edges)}
                 , {fun_edges,         lists:sort(Cache#cache.fun_edges)}
                 , {exports,           lists:sort(Cache#cache.exports)}
                 , {load_orders,       lists:sort(Cache#cache.load_orders)}
                 , {non_upgrade_calls, lists:sort(Cache#cache.non_upgrade_calls)}
                 , {checksum,          Cache#cache.checksum} % orddict, already sorted
                 ]
           ],
  write_file(CacheFile,
             ["%%% -*- mode: erlang; coding: latin-1; -*-\n", String]).

pre_check_cache(Beams, #cache{checksum=Checksum} = Cache) ->
  %% Check that all beams are in the cache, and that all cache files
  %% are still present. Otherwise return an empty cache. This could be
  %% made more efficiently, but we do not add/remove files that often,
  %% so it is ok.
  KeySet  = ordsets:from_list(orddict:fetch_keys(Checksum)),
  BeamSet = ordsets:from_list(Beams),
  case KeySet =:= BeamSet of
    true  -> Cache;
    false -> #cache{}
  end.

checksum(Term) ->
  erlang:md5(term_to_binary(Term)).

check_cache(File, Current, #cache{checksum=Checksums}) ->
  case orddict:find(File, Checksums) of
    {ok, C} when C =:= Current -> ok;
    _ -> stale
  end.

update_cache(File, Current, #cache{checksum=Checksums} = Cache) ->
  Cache#cache{checksum=orddict:store(File, Current, Checksums)}.

%%% Helper functions ===================================================

write_file(File, Payload) ->
  case file:write_file(File, Payload) of
    ok              -> ok;
    {error, Reason} -> erlang:error({write_error, {File, Reason}})
  end.

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
