-define(APP, emqx_persistence_mysql).
-define(ECPOOL_WORKER, emqx_persistence_mysql_cli).

-define(INSERT_CONNECT_SQL, <<
    "INSERT INTO `mqtt`.`on_client_connected`(`action`,`node`,`client_id`,`username`,`ip`,`connected_at`)
    VALUES (?,?,?,?,?,?);"
>>).

-define(INSERT_DISCONNECT_SQL, <<
    "INSERT INTO `mqtt`.`on_client_disconnected`(`action`,`node`,`client_id`,`username`,`reason`,`disconnected_at`)
    VALUES (?,?,?,?,?,?);"
>>).

-define(INSERT_PUBLISH_SQL, <<
    "INSERT INTO `mqtt`.`on_client_publish`(`action`,`node`,`client_id`,`username`,`topic`,`msg_id`,`payload`,`ts`)
    VALUES (?,?,?,?,?,?,?,?);"
>>).

-define(INSERT_PUBLISH_MSG_SQL, <<
    "INSERT INTO `mqtt`.`t_publish_msg`(`msg_id`,`sender`,`topic`,`payload`,`create_time`,`sender_ip`)
    VALUES (?,?,?,?,?,?);"
>>).

-define(INSERT_CONSUME_MSG_SQL, <<
    "INSERT INTO `mqtt`.`t_consume_msg`(`msg_id`,`client_id`,`create_time`)
    VALUES (?,?,?);"
>>).

-define(INSERT_OFFLINE_MSG_SQL, <<
    "INSERT INTO `mqtt`.`mqtt_msg`(`msgid`,`sender`,`topic`,`payload`,`arrived`)
    VALUES (?,?,?,?,?);"
>>).
