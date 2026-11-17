class profile::filebeat (
  String $os_host,
  String $os_password,
  String $os_user = 'admin',
) {
  # filebeat 7.12.1 (OSS build) is the last version that works with OpenSearch
  exec { 'elastic_oss_key':
    command => 'curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic.gpg',
    path    => ['/usr/bin', '/bin'],
    creates => '/usr/share/keyrings/elastic.gpg',
  }

  file { '/etc/apt/sources.list.d/elastic-oss-7.x.list':
    content => "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/oss-7.x/apt stable main\n",
    require => Exec['elastic_oss_key'],
    notify  => Exec['filebeat_apt_update'],
  }

  exec { 'filebeat_apt_update':
    command     => 'apt-get update',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
  }

  package { 'filebeat':
    ensure  => '7.12.1',
    require => Exec['filebeat_apt_update'],
  }

  file { '/etc/filebeat/filebeat.yml':
    content => @("EOT"),
      filebeat.inputs:
        - type: log
          paths: ["/var/log/mysql/error.log"]
          fields: { log_type: mariadb_error }
          fields_under_root: true
        - type: log
          paths: ["/var/log/galera-status.json"]
          json.keys_under_root: true
          json.overwrite_keys: true
          json.add_error_key: true
          fields: { log_type: galera_status }
          fields_under_root: true

      # 7.12.1 crashes on newer glibc/Ubuntu with its default syscall filter
      seccomp.enabled: false

      setup.ilm.enabled: false
      setup.template.enabled: false

      output.elasticsearch:
        hosts: ["https://${os_host}:9200"]
        username: "${os_user}"
        password: "${os_password}"
        ssl.verification_mode: none
        index: "galera-logs-%{+yyyy.MM.dd}"
      | EOT
    mode    => '0600',
    require => Package['filebeat'],
    notify  => Service['filebeat'],
  }

  # clear systemd's "start request repeated too quickly" state when config changes
  exec { 'filebeat_reset_failed':
    command     => 'systemctl reset-failed filebeat',
    path        => ['/usr/bin', '/bin'],
    refreshonly => true,
    subscribe   => File['/etc/filebeat/filebeat.yml'],
    before      => Service['filebeat'],
  }

  # OpenSearch must be answering before filebeat starts
  exec { 'wait_for_opensearch':
    command   => "curl -skf -u ${os_user}:${os_password} https://${os_host}:9200/_cluster/health",
    path      => ['/usr/bin', '/bin'],
    tries     => 30,
    try_sleep => 10,
    before    => Service['filebeat'],
  }

  service { 'filebeat':
    ensure => running,
    enable => true,
  }
}
