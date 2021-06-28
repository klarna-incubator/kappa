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
%% @private
-module(kappa_sup).
-behaviour(supervisor).

%%%_* Exports ==========================================================
%% API
-export([ start_link/0 ]).

%% Callbacks
-export([ init/1 ]).

%%%_* Defines ==========================================================
-define(SERVER, ?MODULE).

%%%_* Code =============================================================

%%%_* API --------------------------------------------------------------
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%_* Callbacks --------------------------------------------------------
init([]) ->
  KappaServer = {kappa_server, {kappa_server, start_link, []},
                 permanent, 2000, worker, [kappa_server]},
  {ok, {{one_for_one, 50, 10}, [ KappaServer ]}}.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
