class profile::galera (
  Hash   $nodes,
  String $bootstrap_node,
  String $cluster_name = 'galera_cluster',
) {
  $hostname  = $facts['networking']['hostname']
  $node_ip   = $nodes[$hostname]
  $addresses = join($nodes.map |$k, $v| { $v }, ',')
  $flag      = '/var/lib/mysql/.galera_initialized'

  package { ['mariadb-server', 'mariadb-client', 'mariadb-backup', 'galera-4', 'rsync']:
    ensure => installed,
  }

  file { '/var/log/mysql':
    ensure  => directory,
    owner   => 'mysql',
    group   => 'adm',
    mode    => '0750',
    require => Package['mariadb-server'],
  }

  file { '/etc/mysql/mariadb.conf.d/60-galera.cnf':
    content => @("EOT"),
      [mysqld]
      bind-address = 0.0.0.0
      binlog_format = ROW
      default_storage_engine = InnoDB
      innodb_autoinc_lock_mode = 2
      log_error = /var/log/mysql/error.log

      [galera]
      wsrep_on = ON
      wsrep_provider = /usr/lib/galera/libgalera_smm.so
      wsrep_cluster_name = ${cluster_name}
      wsrep_cluster_address = gcomm://${addresses}
      wsrep_node_name = ${hostname}
      wsrep_node_address = ${node_ip}
      wsrep_sst_method = rsync
      | EOT
    require => [Package['mariadb-server'], Package['galera-4'], File['/var/log/mysql']],
  }

  # One-time init: stop the standalone instance the package started,
  # then bootstrap (first node) or join (other nodes).
  if $hostname == $bootstrap_node {
    $init_cmd = "systemctl stop mariadb; galera_new_cluster && touch ${flag}"
  } else {
    $init_cmd = "systemctl stop mariadb; systemctl start mariadb && touch ${flag}"
  }

  exec { 'galera_init':
    command => "/bin/bash -c '${init_cmd}'",
    path    => ['/usr/bin', '/bin', '/usr/sbin'],
    creates => $flag,
    timeout => 900,
    require => File['/etc/mysql/mariadb.conf.d/60-galera.cnf'],
  }

  service { 'mariadb':
    ensure  => running,
    enable  => true,
    require => Exec['galera_init'],
  }

  # health collector: one JSON line per minute, shipped by filebeat
  file { '/usr/local/bin/galera_status.sh':
    source => 'puppet:///modules/profile/galera_status.sh',
    mode   => '0755',
  }

  file { '/etc/cron.d/galera-status':
    content => "* * * * * root /usr/local/bin/galera_status.sh\n",
    require => File['/usr/local/bin/galera_status.sh'],
  }

  file { '/etc/logrotate.d/galera-status':
    content => "/var/log/galera-status.json {\n  daily\n  rotate 7\n  compress\n  copytruncate\n  missingok\n  notifempty\n}\n",
  }
}
