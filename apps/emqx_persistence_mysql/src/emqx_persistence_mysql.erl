-module(emqx_persistence_mysql).

-include("emqx_persistence_mysql.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-define(PERSISTENCE_KEY, "$MYSQL").

-export([ load/1,
          unload/0]).
-export([ on_client_connected/3,
          on_client_disconnected/4,
          on_client_subscribe/4
        ]).
-export([ on_message_publish/2]).

load(Env) ->
    emqx:hook('client.connect',       {?MODULE, on_client_connect, [Env]}),
    emqx:hook('client.connack',       {?MODULE, on_client_connack, [Env]}),
    emqx:hook('client.connected',     {?MODULE, on_client_connected, [Env]}),
    emqx:hook('client.disconnected',  {?MODULE, on_client_disconnected, [Env]}),
    emqx:hook('client.authenticate',  {?MODULE, on_client_authenticate, [Env]}),
    emqx:hook('client.check_acl',     {?MODULE, on_client_check_acl, [Env]}),
    emqx:hook('client.subscribe',     {?MODULE, on_client_subscribe, [Env]}),
    emqx:hook('client.unsubscribe',   {?MODULE, on_client_unsubscribe, [Env]}),
    emqx:hook('session.created',      {?MODULE, on_session_created, [Env]}),
    emqx:hook('session.subscribed',   {?MODULE, on_session_subscribed, [Env]}),
    emqx:hook('session.unsubscribed', {?MODULE, on_session_unsubscribed, [Env]}),
    emqx:hook('session.resumed',      {?MODULE, on_session_resumed, [Env]}),
    emqx:hook('session.discarded',    {?MODULE, on_session_discarded, [Env]}),
    emqx:hook('session.takeovered',   {?MODULE, on_session_takeovered, [Env]}),
    emqx:hook('session.terminated',   {?MODULE, on_session_terminated, [Env]}),
    emqx:hook('message.publish',      {?MODULE, on_message_publish, [Env]}),
    emqx:hook('message.delivered',    {?MODULE, on_message_delivered, [Env]}),
    emqx:hook('message.acked',        {?MODULE, on_message_acked, [Env]}),
    emqx:hook('message.dropped',      {?MODULE, on_message_dropped, [Env]}).


unload() ->
    emqx:unhook('client.connect',       {?MODULE, on_client_connect}),
    emqx:unhook('client.connack',       {?MODULE, on_client_connack}),
    emqx:unhook('client.connected',     {?MODULE, on_client_connected}),
    emqx:unhook('client.disconnected',  {?MODULE, on_client_disconnected}),
    emqx:unhook('client.authenticate',  {?MODULE, on_client_authenticate}),
    emqx:unhook('client.check_acl',     {?MODULE, on_client_check_acl}),
    emqx:unhook('client.subscribe',     {?MODULE, on_client_subscribe}),
    emqx:unhook('client.unsubscribe',   {?MODULE, on_client_unsubscribe}),
    emqx:unhook('session.created',      {?MODULE, on_session_created}),
    emqx:unhook('session.subscribed',   {?MODULE, on_session_subscribed}),
    emqx:unhook('session.unsubscribed', {?MODULE, on_session_unsubscribed}),
    emqx:unhook('session.resumed',      {?MODULE, on_session_resumed}),
    emqx:unhook('session.discarded',    {?MODULE, on_session_discarded}),
    emqx:unhook('session.takeovered',   {?MODULE, on_session_takeovered}),
    emqx:unhook('session.terminated',   {?MODULE, on_session_terminated}),
    emqx:unhook('message.publish',      {?MODULE, on_message_publish}),
    emqx:unhook('message.delivered',    {?MODULE, on_message_delivered}),
    emqx:unhook('message.acked',        {?MODULE, on_message_acked}),
    emqx:unhook('message.dropped',      {?MODULE, on_message_dropped}).

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
    emqx_persistence_mysql_cli:insert(connected, Data),
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
    emqx_persistence_mysql_cli:insert(disconnected, Data),
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
    emqx_persistence_mysql_cli:insert(publish, Data),
    {ok, Message};

on_message_publish(Message , _Env) ->
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
