class profile::dashboards {
  $cfg = '/etc/opensearch-dashboards/opensearch_dashboards.yml'

  # same signing key that profile::opensearch already installed
  file { '/etc/apt/sources.list.d/opensearch-dashboards-2.x.list':
    content => "deb [signed-by=/usr/share/keyrings/opensearch.gpg] https://artifacts.opensearch.org/releases/bundle/opensearch-dashboards/2.x/apt stable main\n",
    require => Exec['opensearch_key'],
    notify  => Exec['dashboards_apt_update'],
  }

  exec { 'dashboards_apt_update':
    command     => 'apt-get update',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  package { 'opensearch-dashboards':
    ensure  => installed,
    require => Exec['dashboards_apt_update'],
  }

  # The package default already points at https://localhost:9200 with the
  # built-in kibanaserver user. We only need to listen on all interfaces.
  exec { 'dashboards_listen_all':
    command  => "sed -i '/^server.host:/d' ${cfg} && echo 'server.host: 0.0.0.0' >> ${cfg}",
    unless   => "grep -qx 'server.host: 0.0.0.0' ${cfg}",
    provider => shell,
    require  => Package['opensearch-dashboards'],
    notify   => Service['opensearch-dashboards'],
  }

  service { 'opensearch-dashboards':
    ensure  => running,
    enable  => true,
    require => Package['opensearch-dashboards'],
  }
}
