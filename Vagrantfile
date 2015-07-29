# vim: set filetype=ruby:
require 'yaml'

configuration = YAML.load_file 'vagrant.yml'
settings = configuration['vagrant']
instances = configuration['instances']

Vagrant.configure('2') do |config|

  unless Vagrant.has_plugin?("vagrant-vbguest")
    puts 'Vagrant \'vagrant-vbguest\' is required but is not installed'
    puts 'please check if you have the plugin with the following command:'
    puts '    $ vagrand plugin list'
    puts 'If needed install the plugin:'
    puts '    $ vagrant plugin install vagrant-vbguest'
    abort 'Missing vagrant-vbguest plugin'
  end

  @min_memory = settings['min_memory']
  @min_cores = settings['min_cores']
  @max_cores = `nproc`.to_i

  config.vm.box     = settings['default_box']
  config.vm.box_url = settings['default_box_url']
  config.ssh.forward_agent = true
  config.ssh.insert_key = settings['ssh_insert_key']
  config.vm.box_check_update = true
  config.vbguest.auto_update = false

  instances.each do |instance|

    config.vm.define instance['hostname'] do |guest|

      if instance.has_key? 'box'
        guest.vm.box = instance['box']
      end
      if instance.has_key? 'box_url'
        guest.vm.box_url = instance['box_url']
      end

      if instance.has_key? 'private_ip'
        guest.vm.network 'private_network', ip: instance['private_ip']
      end

      guest.vm.provider 'virtualbox' do |vb|
        if instance.has_key? 'cpu_execution_cap'
          vb.customize ["modifyvm", :id, "--cpuexecutioncap", instance['cpu_execution_cap'].to_s]
        end

        if instance.has_key? 'memory'
          vb.memory = instance['memory']
        else
          vb.memory = @min_memory
        end

        if !instance.has_key? 'cores'
          vb.cpus = @min_cores
        elsif instance['cores'] == 'max'
          vb.cpus = @max_cores
        else
          vb.cpus = instance['cores']
        end
      end

      if instance.has_key? 'mounts'
        instance['mounts'].each do |mount|
          guest.vm.synced_folder mount['host_path'], mount['guest_path'], owner: mount['owner'], group: mount['group']
        end
      end

    end

  end

end
