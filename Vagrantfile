# -*- mode: ruby -*-
# vi: set ft=ruby :

require 'yaml'

# Read YAML config file
vagrant_config  = YAML.load_file('settings.yml')
kubernetes = vagrant_config['kubernetes']
proxies = vagrant_config['proxies']

# The number of nodes to provision
num_nodes = (kubernetes['num_nodes'] || 2).to_i
# ip configuration
master_ip = kubernetes['master_ip'] || "192.168.100.21"
node_ips = num_nodes.times.collect { |n| master_ip.gsub(/(\d+\.\d+\.\d+\.)(\d+)/) \
  {$1 + ($2.to_i + n + 1).to_s} }
# prefix of vm name
instance_prefix = kubernetes['instance_prefix'] || "k8s"
# kubernetes token
kube_token = kubernetes['token'] || "e08460.ce88228cf4f8951c"
# Determine the box to use
kube_box_name = kubernetes['box_name'] || "ubuntu/xenial64"
# Give VM 2 of CPU by default
vm_cpus = (kubernetes['vm_cpus'] || 2).to_i
# Give VM 1024MB of RAM to master and 2048 MB of RAM to nodes by default
vm_master_mem = (kubernetes['vm_master_mem'] || 1024).to_i
vm_node_mem = (kubernetes['vm_node_mem'] || 2048).to_i

Vagrant.configure("2") do |config|
  required_plugins = %w(vagrant-vbguest vagrant-timezone vagrant-proxyconf vagrant-hosts)
  plugins_to_install = required_plugins.select { |plugin| not Vagrant.has_plugin? plugin }
  if not plugins_to_install.empty?
    puts "Installing plugins: #{plugins_to_install.join(' ')}"
    if system "vagrant plugin install #{plugins_to_install.join(' ')}"
      exec "vagrant #{ARGV.join(' ')}"
    else
      abort "Installation of one or more plugins has failed. Aborting."
    end
  end

  config.timezone.value = :host
  
  if Vagrant.has_plugin?("vagrant-proxyconf") then
    config.proxy.http = proxies['http'] || ""
    config.proxy.https = proxies['https'] || ""
    config.proxy.no_proxy = proxies['no_proxy'] || "127.0.0.1,localhost,#{master_ip},#{node_ips.join(',')}"
  end

  if Vagrant.has_plugin?("vagrant-hosts") then
    config.vm.provision :hosts do |provisioner|
      provisioner.autoconfigure = true
      provisioner.sync_hosts = true
    end
  end

  # Don't attempt to update Virtualbox Guest Additions (requires gcc)
  if Vagrant.has_plugin?("vagrant-vbguest") then
    config.vbguest.auto_update = false
  end

  config.vm.box_check_update = false
  config.ssh.forward_x11 = true

  # Kubernetes box name
  config.vm.box = kube_box_name

  config.vm.synced_folder ".", "/vagrant", type: "virtualbox"

  config.vm.provision "shell" do |s|
    ssh_pub_key = File.readlines("#{Dir.home}/.ssh/id_rsa.pub").first.strip
    s.inline = <<-SHELL
      mkdir -p /root/.ssh
      echo #{ssh_pub_key} > /root/.ssh/authorized_keys
    SHELL
  end

  # Kubernetes master
  master_vm_name = "#{instance_prefix}-master"

  config.vm.define master_vm_name do |master|
    master.vm.hostname = master_vm_name
    master.vm.network "private_network", ip: "#{master_ip}"
    master.vm.provider "virtualbox" do |vb|
      vb.name = master_vm_name
      vb.cpus = vm_cpus
      vb.memory = vm_master_mem
    end
    master.vm.provision "shell" do |s|
      s.path = "scripts/install-k8s.sh"
      s.args = [ "-s", "master", "-a", "#{master_ip}", "-t", "#{kube_token}" ]
    end
  end

  # Kubernetes node
  num_nodes.times do |n|
    node_vm_name = "#{instance_prefix}-node-#{n + 1}"

    config.vm.define node_vm_name do |node|
      node.vm.hostname = node_vm_name
      node.vm.network "private_network", ip: "#{node_ips[n]}"
      node.vm.provider "virtualbox" do |vb|
        vb.name = node_vm_name
        vb.cpus = vm_cpus
        vb.memory = vm_node_mem
      end
      node.vm.provision "shell" do |s|
        s.path = "scripts/install-k8s.sh"
        s.args = [ "-s", "node", "-a", "#{master_ip}", "-t", "#{kube_token}" ]
      end
    end
  end
end