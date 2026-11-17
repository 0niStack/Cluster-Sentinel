class profile::opensearch (
  String $admin_password,
  String $cluster_name = 'logs',
) {
  $cfg = '/etc/opensearch/opensearch.yml'

  exec { 'opensearch_key':
    command => 'curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp | gpg --dearmor -o /usr/share/keyrings/opensearch.gpg',
    path    => ['/usr/bin', '/bin'],
    creates => '/usr/share/keyrings/opensearch.gpg',
  }

  file { '/etc/apt/sources.list.d/opensearch-2.x.list':
    content => "deb [signed-by=/usr/share/keyrings/opensearch.gpg] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main\n",
    require => Exec['opensearch_key'],
    notify  => Exec['opensearch_apt_update'],
  }

  exec { 'opensearch_apt_update':
    command     => 'apt-get update',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  # OpenSearch will not start without this
  exec { 'max_map_count':
    command => 'echo "vm.max_map_count=262144" > /etc/sysctl.d/99-opensearch.conf && sysctl -p /etc/sysctl.d/99-opensearch.conf',
    path    => ['/usr/sbin', '/usr/bin', '/bin'],
    unless  => 'test "$(sysctl -n vm.max_map_count)" -ge 262144',
  }

  # 2.12+ requires the initial admin password at install time.
  # The package also generates the security/SSL config in opensearch.yml.
  exec { 'install_opensearch':
    command     => 'apt-get install -y opensearch',
    environment => ["OPENSEARCH_INITIAL_ADMIN_PASSWORD=${admin_password}", 'DEBIAN_FRONTEND=noninteractive'],
    path        => ['/usr/bin', '/bin'],
    creates     => '/usr/share/opensearch/bin/opensearch',
    timeout     => 900,
    require     => [Exec['opensearch_apt_update'], Exec['max_map_count']],
  }

  # Edit only the settings we need; keep the package's security/SSL lines.
  $settings = {
    'network.host'   => '0.0.0.0',
    'discovery.type' => 'single-node',
    'cluster.name'   => $cluster_name,
    'node.name'      => $facts['networking']['hostname'],
  }

  $settings.each |$k, $v| {
    exec { "opensearch_set_${k}":
      command  => "sed -i '/^${k}:/d' ${cfg} && echo '${k}: ${v}' >> ${cfg}",
      unless   => "grep -qx '${k}: ${v}' ${cfg}",
      provider => shell,
      require  => Exec['install_opensearch'],
      notify   => Service['opensearch'],
    }
  }

  service { 'opensearch':
    ensure  => running,
    enable  => true,
    require => Exec['install_opensearch'],
  }
}
