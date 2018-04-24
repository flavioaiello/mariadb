# MariaDB

## Docker Build
When deploying the official docker hub mariadb image, an unspecific default configuration file will be provided, thus no performance parameters are set nor the container limits are taken into account. The result is poor database performance and many issues if not mitigated properly.

Based on the official images, the custom image as outlined below is recommended for a mariadb connection pool tandem with the great [Hikari](https://github.com/brettwooldridge/HikariCP) library reaching a basic performance level.

## Compose sample excerpt
(Please pass your own credentials or let them be generated automatically, don't use these ones for production!)
```
...
  image: ${REGISTRY}/mariadb:latest
  environment:
    MYSQL_ROOT_PASSWORD: asg23ADFr9R4r76
    MYSQL_DATABASE: wordpressdb
    MYSQL_USER: wordpressuser
    MYSQL_PASSWORD: hguyFt6S95dgfR4ryb
  expose:
    - "3306"
  volumes:
    - /data/example/mysql:/var/lib/mysql
  ...
```

## Volume structure
* `/var/lib/mysql`: Database files
* `/var/lib/mysql/mysql-bin`: MariaDB logs

## Environment Variables
When you start the mariadb image, you can adjust the configuration of the MariaDB instance by passing one or more environment variables on the docker run command line. Do note that none of the variables below will have any effect if you start the container with a data directory that already contains a database: any pre-existing database will always be left untouched on container startup.
### `MYSQL_ROOT_PASSWORD`
This variable is mandatory and specifies the password that will be set for the MariaDB root superuser account.
### `MYSQL_DATABASE`
This variable is optional and allows you to specify the name of a database to be created on image startup. If a user/password was supplied (see below) then that user will be granted superuser access (corresponding to GRANT ALL) to this database.
### `MYSQL_USER`, `MYSQL_PASSWORD`
These variables are optional, used in conjunction to create a new user and to set that user's password. This user will be granted superuser permissions (see above) for the database specified by the MYSQL_DATABASE variable. Both variables are required for a user to be created.
### `SLOW_QUERY_LOG`
Records all slow queries exeding the long query time span below - enabled `1` (default) - disabled `0`
### `LONG_QUERY_TIME`
A slow query is defined as a query that takes longer to run, by default 5 seconds.


## Hikari
The mariadb `wait_timeout` parameter is limited by the swarm overlay network constraint of terminating tcp connections after 15 minutes. In order to set the hikari `maxLifetime` parameter to 10 minutes, the `wait_timeout` parameter must be increased from `600` to `750` seconds as shown above.

## Swarm
When using overlay networking with Docker swarm mode or other orchestrators, the ip address of containers will be provisioned on a short term basis. By default a lookup on every request is made and cached. Disabling both, `skip-host-cache` and `skip-name-resolve` improves the performance of each query.

## Example Dockerfile
The Dockerfile excerpt below can be found on Github as referenced in the footer.
```
...
RUN sed -re 's/^(bind-address|log|user)/#&/' \
    -e '/wait_timeout[^_]\s*/c\wait_timeout = 750' \
    -e '/\[mysqld\]/a skip-host-cache' \
    -e '/\[mysqld\]/a skip-name-resolve' \
    -i /etc/mysql/my.cnf
...
```
## Container limits
Taking container limits into account and calculating on startup buffer and cache size parameters, leads to a vastly performance improvement. `AWK` is the simplest command available to do the math based on the cgroup parameters, calculating the required integers as shown below:

## Example entrypoint.sh
The entrypoint excerpt below can be found on Github as referenced in the footer.
```
...
sed -e "/innodb_buffer_pool_size[^_]\s*/c\innodb_buffer_pool_size = $(awk '{ print int($1*3/4)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/tmp_table_size[^_]\s*/c\tmp_table_size = $(awk '{ print int($1/16)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/max_heap_table_size[^_]\s*/c\max_heap_table_size = $(awk '{ print int($1/16)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/query_cache_limit[^_]\s*/c\query_cache_limit = $(awk '{ print int($1/6000)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/query_cache_size[^_]\s*/c\query_cache_size = $(awk '{ print int($1/12)}' /sys/fs/cgroup/memory/memory.limit_in_bytes)" \
    -e "/slow_query_log[^_]\s*/c\slow_query_log = ${SLOW_QUERY_LOG:-1}" \
    -e "/long_query_time[^_]\s*/c\long_query_time = ${LONG_QUERY_TIME:-5}" \
    -i /etc/mysql/my.cnf
...
```

## Parameters

### innodb_buffer_pool_size
InnoDB buffer pool size in bytes. The primary value to adjust on a database server with entirely/primarily XtraDB/InnoDB tables, can be set up to 80% of the total memory in these environments. If set to 2 GB or more, you will probably want to adjust innodb_buffer_pool_instances as well. See the XtraDB/InnoDB Buffer Pool for more on setting this variable, and also Setting Innodb Buffer Pool Size Dynamically if doing so dynamically.

### tmp_table_size
The largest size for temporary tables in memory (not MEMORY tables) although if max_heap_table_size is smaller the lower limit will apply. If a table exceeds the limit, MariaDB converts it to a MyISAM or Aria table. You can see if it's necessary to increase by comparing the status variables Created_tmp_disk_tables and Created_tmp_tables to see how many temporary tables out of the total created needed to be converted to disk. Often complex GROUP BY queries are responsible for exceeding the limit. Defaults may be different on some systems, see for example Differences in MariaDB in Debian. From MariaDB 10.2.7, tmp_memory_table_size is an alias.

### max_heap_table_size
Maximum size in bytes for user-created MEMORY tables. Setting the variable while the server is active has no effect on existing tables unless they are recreated or altered. The smaller of max_heap_table_size and tmp_table_size also limits internal in-memory tables. When the maximum size is reached, any further attempts to insert data will receive a "table ... is full" error. Temporary tables created with CREATE TEMPORARY will not be converted to Aria, as occurs with internal temporary tables, but will also receive a table full error.

### query_cache_limit
Size in bytes for which results larger than this are not stored in the query cache.

### query_cache_size
Size in bytes available to the query cache. About 40KB is needed for query cache structures, so setting a size lower than this will result in a warning. 0, the default before MariaDB 10.1.7, effectively disables the query cache. Starting from MariaDB 10.1.7, query_cache_type is automatically set to ON if the server is started with the query_cache_size set to a non-zero (and non-default) value.

### Slow query logging
Finally the slow query logging will be activated and the threshold set to 5 seconds.
