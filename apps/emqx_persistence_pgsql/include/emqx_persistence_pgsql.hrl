-define(APP, emqx_persistence_pgsql).
-define(ECPOOL_WORKER, emqx_persistence_pgsql_cli).

-define(INSERT_CONNECT_SQL, <<
    "INSERT INTO on_client_connected(id,action,node,client_id,username,ip,connected_at)
    VALUES (DEFAULT,$1,$2,$3,$4,$5,$6);"
>>).

-define(INSERT_DISCONNECT_SQL, <<
    "INSERT INTO on_client_disconnected(id,action,node,client_id,username,reason,disconnected_at)
    VALUES (DEFAULT,$1,$2,$3,$4,$5,$6);"
>>).

-define(INSERT_PUBLISH_MSG_SQL, <<
    "INSERT INTO t_publish_msg(id,msg_id,sender,topic,payload,create_time,sender_ip)
    VALUES (DEFAULT,$1,$2,$3,$4,$5,$6);"
>>).

-define(INSERT_CONSUME_MSG_SQL, <<
    "INSERT INTO t_consume_msg(id,msg_id,client_id,create_time)
    VALUES (DEFAULT,$1,$2,$3);"
>>).

-define(INSERT_OFFLINE_MSG_SQL, <<
    "INSERT INTO mqtt_msg(id,msgid,sender,topic,payload,arrived)
    VALUES (DEFAULT,$1,$2,$3,$4,$5);"
>>).
