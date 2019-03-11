#!/bin/bash
set -eo pipefail
shopt -s nullglob

sed -e "/innodb_buffer_pool_size[^_]\s*/c\innodb_buffer_pool_size = $(awk '{ print int($1*2/3)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/tmp_table_size[^_]\s*/c\tmp_table_size = $(awk '{ print int($1/16)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/max_heap_table_size[^_]\s*/c\max_heap_table_size = $(awk '{ print int($1/16)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/query_cache_limit[^_]\s*/c\query_cache_limit = $(awk '{ print int($1/6000)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/query_cache_size[^_]\s*/c\query_cache_size = $(awk '{ print int($1/12)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/slow_query_log[^_]\s*/c\slow_query_log = ${SLOW_QUERY_LOG:-1}" \
    -e "/long_query_time[^_]\s*/c\long_query_time = ${LONG_QUERY_TIME:-5}" \
    -i /etc/mysql/my.cnf

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
    set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
    case "$arg" in
        -'?'|--help|--print-defaults|-V|--version)
            wantHelp=1
            break
            ;;
    esac
done

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
        exit 1
    fi
    local val="$def"
    if [ "${!var:-}" ]; then
        val="${!var}"
    elif [ "${!fileVar:-}" ]; then
        val="$(< "${!fileVar}")"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

_check_config() {
    toRun=( "$@" --verbose --help --log-bin-index="$(mktemp -u)" )
    if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
        cat >&2 <<-EOM

            ERROR: mysqld failed while attempting to check config
            command was: "${toRun[*]}"

            $errors
		EOM
        # EOM must be indented by tabs!
        exit 1
    fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
_get_config() {
    local conf="$1"; shift
    "$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "'"$conf"'" { print $2; exit }'
}

if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then

    # still need to check config, container may have started with --user
    _check_config "$@"

    # Get config
    SLOWQUERYLOG="$(_get_config 'slow-query-log-file' "$@")"
    LOGDIR="$(dirname "$SLOWQUERYLOG")"
    DATADIR="$(_get_config 'datadir' "$@")"

    # Check log dir and set permissions
    if [ ! -d "$LOGDIR" ]; then
        mkdir -p "$LOGDIR"
    fi
    chown -R mysql:mysql "$LOGDIR"

    # Initialize or update database
    if [ ! -d "$DATADIR/mysql" ]; then

        file_env 'MYSQL_ROOT_PASSWORD'
        if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
            echo >&2 'error: database is uninitialized and password option is not specified '
            echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
            exit 1
        fi

        mkdir -p "$DATADIR"
        chown -R mysql:mysql "$DATADIR"

        echo 'Initializing database'
        mysql_install_db --user="mysql" --datadir="$DATADIR" --rpm
        echo 'Database initialized'

        SOCKET="$(_get_config 'socket' "$@")"
        "$@" --skip-networking --socket="${SOCKET}" &
        pid="$!"

        mysql=( mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" )

        for i in {30..0}; do
            if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
                break
            fi
            echo 'MySQL init process in progress...'
            sleep 1
        done
        if [ "$i" = 0 ]; then
            echo >&2 'MySQL init process failed.'
            exit 1
        fi

        if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
            # sed is for https://bugs.mysql.com/bug.php?id=20545
            mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
        fi

        if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
            export MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
            echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
        fi

        rootCreate=
        # default root to listen for connections from anywhere
        file_env 'MYSQL_ROOT_HOST' '%'
        if [ ! -z "$MYSQL_ROOT_HOST" -a "$MYSQL_ROOT_HOST" != 'localhost' ]; then
            # no, we don't care if read finds a terminating character in this heredoc
            # https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
            read -r -d '' rootCreate <<-EOSQL || true
                CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
                GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
			EOSQL
            # EOSQL must be indented by tabs!
        fi

        "${mysql[@]}" <<-EOSQL
            -- What's done in this file shouldn't be replicated
            --  or products like mysql-fabric won't work
            SET @@SESSION.SQL_LOG_BIN=0;

            DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys', 'root') OR host NOT IN ('localhost') ;
            SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}') ;
            GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
            ${rootCreate}
            DROP DATABASE IF EXISTS test ;
            FLUSH PRIVILEGES ;
		EOSQL
        # EOSQL must be indented by tabs!

        if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
            mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
        fi

        file_env 'MYSQL_DATABASE'
        if [ "$MYSQL_DATABASE" ]; then
            echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | "${mysql[@]}"
            mysql+=( "$MYSQL_DATABASE" )
        fi

        file_env 'MYSQL_USER'
        file_env 'MYSQL_PASSWORD'
        if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
            echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

            if [ "$MYSQL_DATABASE" ]; then
                echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
            fi

            echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
        fi

        echo
        for f in /docker-entrypoint-initdb.d/*; do
            case "$f" in
                *.sh)     echo "$0: running $f"; . "$f" ;;
                *.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
                *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
                *)        echo "$0: ignoring $f" ;;
            esac
            echo
        done

        if ! kill -s TERM "$pid" || ! wait "$pid"; then
            echo >&2 'MySQL start of init process failed.'
            exit 1
        fi

        echo
        echo 'MySQL init process done. Ready for start up.'
        echo

    else
        file_env 'MYSQL_ROOT_PASSWORD'

        echo 'updating database'

        chown -R mysql:mysql "$DATADIR"

        SOCKET="$(_get_config 'socket' "$@")"
        "$@" --user=mysql --skip-networking --socket="${SOCKET}" &
        pid="$!"
        echo "MySQL process pid: $pid"

        mysql=( mysql -uroot -p${MYSQL_ROOT_PASSWORD} -hlocalhost --protocol=socket --socket="${SOCKET}" )

        for i in {30..0}; do
            if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
                break
            fi
            echo 'MySQL init process in progress...'
            sleep 7
        done
        if [ "$i" = 0 ]; then
            echo >&2 'MySQL init process failed.'
            exit 1
        fi

        mysql_upgrade -uroot -p${MYSQL_ROOT_PASSWORD} -hlocalhost --protocol=socket --socket="${SOCKET}"

        if ! kill -s TERM "$pid" || ! wait "$pid"; then
            echo >&2 'MySQL update process failed.'
            exit 1
        fi

        echo
        echo 'MySQL update process done. Ready for start up.'
        echo
    fi
fi

echo '*** Starting database ***'
exec "$@"
