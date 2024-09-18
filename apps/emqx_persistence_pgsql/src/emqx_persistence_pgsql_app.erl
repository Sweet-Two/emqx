-module(emqx_persistence_pgsql_app).

-behaviour(application).

-include("emqx_persistence_pgsql.hrl").

-emqx_plugin(?APP).

-export([ start/2
        , stop/1
        ]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = emqx_persistence_pgsql_sup:start_link(),
    ?APP:load([]),
    {ok, Sup}.

stop(_State) ->
    ?APP:unload(),
    ok.
