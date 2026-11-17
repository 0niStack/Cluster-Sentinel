# Values below are filled in automatically by deploy.sh
$os_ip       = '@OS_IP@'
$os_password = '@OS_PASS@'
$galera_nodes = {
  'galera01' => '@G1@',
  'galera02' => '@G2@',
  'galera03' => '@G3@',
}

node /^os01/ {
  class { 'profile::opensearch':
    admin_password => $os_password,
  }
  class { 'profile::dashboards':
    require => Class['profile::opensearch'],
  }
}

node /^galera0[123]/ {
  class { 'profile::galera':
    nodes          => $galera_nodes,
    bootstrap_node => 'galera01',
  }
  class { 'profile::filebeat':
    os_host     => $os_ip,
    os_password => $os_password,
    require     => Class['profile::galera'],
  }
}
