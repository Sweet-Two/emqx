-module(emqx_persistence_pgsql).

-include("emqx_persistence_pgsql.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-define(PERSISTENCE_KEY, "$MYSQL").

-export([ load/1,
          unload/0]).

%% Client Lifecircle Hooks
-export([ on_client_connected/3,
          on_client_disconnected/4,
          on_client_subscribe/4
        ]).

%% Session Lifecircle Hooks
-export([ on_session_subscribed/4
        ]).

%% Message Pubsub Hooks
-export([ on_message_publish/2,
          on_message_acked/3
        ]).

load(Env) ->
    emqx:hook('message.publish',     {?MODULE, on_message_publish, [Env]}),
    emqx:hook('session.subscribed',  {?MODULE, on_session_subscribed, [Env]}),
    emqx:hook('message.acked',       {?MODULE, on_message_acked, [Env]}),
    emqx:hook('client.connected',    {?MODULE, on_client_connected, [Env]}),
    emqx:hook('client.disconnected', {?MODULE, on_client_disconnected, [Env]}).

unload() ->
    emqx:unhook('message.publish',     {?MODULE, on_message_publish}),
    emqx:unhook('session.subscribed',  {?MODULE, on_session_subscribed}),
    emqx:unhook('message.acked',       {?MODULE, on_message_acked}),
    emqx:unhook('client.connected',    {?MODULE, on_client_connected}),
    emqx:unhook('client.disconnected', {?MODULE, on_client_disconnected}).

%%--------------------------------------------------------------------
%% Client subscribe
%%--------------------------------------------------------------------

on_client_subscribe(#{clientid := _ClientId, username := _Username}, _Properties, RawTopicFilters, _) ->
    lists:foreach(fun({Topic, _Opts}) ->
        case string:left(erlang:binary_to_list(Topic), erlang:length(?PERSISTENCE_KEY)) of
            ?PERSISTENCE_KEY ->
                {stop, deny};
            _ ->
                {matched, allow}
        end
    end, RawTopicFilters).
%%--------------------------------------------------------------------
%% Client connected
%%--------------------------------------------------------------------
on_client_connected(#{clientid := ClientId,
                      username := Username,
                      peerhost := Peerhost}, ConnInfo, _Env) ->
    Action = <<"client_connected">>,
    Node = erlang:atom_to_binary(node()),
    Ipaddress = iolist_to_binary(inet:ntoa(Peerhost)),
    ConnectedAt = maps:get(connected_at, ConnInfo),
    Data = [Action, Node, stringfy(ClientId), stringfy(Username),
            Ipaddress, ConnectedAt],
    emqx_persistence_pgsql_cli:insert(?INSERT_CONNECT_SQL, Data),
    ok.

%%--------------------------------------------------------------------
%% Client disconnected
%%--------------------------------------------------------------------
on_client_disconnected(#{clientid := ClientId,
                         username := Username}, Reason, ConnInfo, _Env) ->
    Action = <<"client_disconnected">>,
    Node = erlang:atom_to_binary(node()),
    DisconnectedAt = maps:get(disconnected_at, ConnInfo, erlang:system_time(millisecond)),
    Data = [Action, Node, stringfy(ClientId), stringfy(Username), stringfy(Reason), DisconnectedAt],
    ?LOG(info, "[Persistence_plugin]test:~p~n", [Data]),
    emqx_persistence_pgsql_cli:insert(?INSERT_DISCONNECT_SQL, Data),
    ok.

on_session_subscribed(#{clientid := ClientId}, Topic, SubOpts, _Env) ->
    ?LOG(info, "[Persistence_plugin]Session(~s) subscribed ~s with subopts: ~p~n", [ClientId, Topic, SubOpts]),
  ok.


%%--------------------------------------------------------------------
%% Message publish
%%--------------------------------------------------------------------
on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(Message = #message{topic = <<?PERSISTENCE_KEY, _/binary>> = _Topic}, _Env) ->
    {FromClientId, FromUsername} = parse_from(Message),
    Action = <<"message_publish">>,
    Node = erlang:atom_to_binary(node()),
    Topic = Message#message.topic,
    MsgId = emqx_guid:to_hexstr(Message#message.id),
    Payload = Message#message.payload,
    Ts = Message#message.timestamp,
    Data = [Action, Node, stringfy(FromClientId),
                          stringfy(FromUsername), Topic, MsgId, Payload, Ts],
    ?LOG(info, "[Persistence_plugin]test:~p~n", [Data]),
    MyData = [MsgId, stringfy(FromClientId), Topic, Payload, Ts, Node],
    emqx_persistence_pgsql_cli:insert(?INSERT_PUBLISH_MSG_SQL, MyData),
    {ok, Message};

on_message_publish(Message , _Env) ->
    {ok, Message}.

%%--------------------------------------------------------------------
%% Message acked
%%--------------------------------------------------------------------
on_message_acked(_ClientInfo = #{clientid := ClientId}, Message, _Env) ->
    ?LOG(info,"[Persistence_plugin]Message acked by client(~s): ~s~n",
        [ClientId, emqx_message:format(Message)]),
    MsgId = emqx_guid:to_hexstr(Message#message.id),
    Topic = Message#message.topic,
    Payload = Message#message.payload,
    Timestamp = Message#message.timestamp,
    Data = [MsgId, stringfy(ClientId), Topic, Payload, Timestamp],
    ?LOG(info, "[Persistence_plugin]test:~p~n", [Data]),
    emqx_persistence_pgsql_cli:insert(?INSERT_OFFLINE_MSG_SQL, Data),
    {ok, Message}.
%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

maybe(undefined) -> null;

maybe(Str) -> Str.

stringfy(Term) when is_binary(Term) ->
    Term;
stringfy(Term) when is_atom(Term) ->
    atom_to_binary(Term, utf8);
stringfy(Term) ->
    unicode:characters_to_binary((io_lib:format("~0p", [Term]))).
parse_from(Message) ->
    {emqx_message:from(Message), maybe(emqx_message:get_header(username, Message))}.
