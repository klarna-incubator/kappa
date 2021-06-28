#!/usr/bin/env escript
%% -*- mode: erlang -*-
%%! -pz lib/getopt/ebin lib/kappa/ebin lib/image/ebin
-module(kappa_wrapper).

%%%_* Code =============================================================
%%%_* Entrypoint -------------------------------------------------------
main(Args) -> kappa_check:main(Args).
