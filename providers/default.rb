def whyrun_supported?
  true
end

use_inline_resources

action :install do
  node_type = @new_resource.node_type
  Chef::Log.info("Setting up a Druid #{node_type} node")

# Create user, group, and necessary folders
  group node[:druid][:group] do
    action :create
  end

  user node[:druid][:user] do
    gid node[:druid][:group]
    home node[:druid][:install_dir]
  end

  directory node[:druid][:install_dir] do
    owner node[:druid][:user]
    group node[:druid][:group]
    mode "0755"
  end

  directory node[:druid][:src_dir] do
    owner node[:druid][:user]
    group node[:druid][:group]
    mode "0755"
  end

  directory node[:druid][:log_path] do
    owner node[:druid][:user]
    group node[:druid][:group]
    mode "0755"
  end

  # Checkout specified revision of druid from specified repo
  package 'git'
  git node[:druid][:src_dir] do
    repository node[:druid][:repository]
    revision node[:druid][:revision]
    action :sync
    user node[:druid][:user]
    group node[:druid][:group]
  end

  druid_archive = "#{node[:druid][:src_dir]}/services/target/druid-#{node[:druid][:version]}*-bin.tar.gz"

  # Build druid, send output to logfile because it's so verbose it seens to causes problems
  package 'maven'
  bash 'compile druid' do
    cwd node[:druid][:src_dir]
    code "mvn clean package -DskipTests &>chef_druid_build.log"
    user node[:druid][:user]
    group node[:druid][:group]
    only_if { ::Dir.glob(druid_archive).empty? }
  end

  # Extract build druid to install dir
  bash 'install druid' do
    cwd Chef::Config[:file_cache_path]
    code "tar -C #{node[:druid][:install_dir]} -zxf #{druid_archive} && " +
         "chown -R #{node[:druid][:user]}:#{node[:druid][:group]} '#{node[:druid][:install_dir]}'"
    user node[:druid][:user]
    group node[:druid][:group]
  end
  
  druid_current_version_path = ::File.join(node[:druid][:install_dir], "druid-#{node[:druid][:version]}")
  link_path = ::File.join(node[:druid][:install_dir], "current")

  # Remove symlink if it exists because otherwise some versions of chef
  # (e.g, 12.0.3) won't properly handle permissions in next step
  bash 'remove druid current version symlink' do
    code "rm #{link_path}"
    only_if { ::File.exists?(link_path)}
  end

  link link_path do
    owner node[:druid][:user]
    group node[:druid][:group]
    to druid_current_version_path
  end

  # Create config directories
  directory ::File.join(node[:druid][:config_dir], node_type) do
    recursive true
    owner node[:druid][:user]
    group node[:druid][:group]
    mode "0755"
  end

  directory ::File.join(node[:druid][:config_dir], "_common") do
    recursive true
    owner node[:druid][:user]
    group node[:druid][:group]
    mode "0755"
  end

  # Select common properties and node type properties
  # Clone doesn't seem to work on node (so just create new Hashes)
  common_props = node[:druid][:properties].inject(Hash.new) { |h, (k, v)| h[k] = v unless v.is_a?(Hash); h }
  type_specific_props = node[:druid][node_type][:properties].inject(Hash.new) { |h, (k, v)| h[k] = v unless v.is_a?(Hash); h }
  type_specific_props["druid.service"] = node_type

  # Write common config file
  common_config_dir = ::File.join(node[:druid][:config_dir], "_common")
  template ::File.join(common_config_dir, "common.runtime.properties") do
    source "properties.erb"
    variables({:properties => common_props})
    owner node[:druid][:user]
    group node[:druid][:group]
  end

  # Write node_type specific config file
  type_specific_config_dir = ::File.join(node[:druid][:config_dir], node_type)
  template ::File.join(type_specific_config_dir, "runtime.properties") do
    source "properties.erb"
    variables({:properties => type_specific_props})
    owner node[:druid][:user]
    group node[:druid][:group]
  end

  # Write node_type specific log4j2 config file
  template ::File.join(type_specific_config_dir, "log4j2.xml") do
    source "log4j2.xml.erb"
    variables({:node_type => node_type})
    owner node[:druid][:user]
    group node[:druid][:group]
  end

  # Startup script, works with upstart template
  service_name = "druid-#{node_type}"
  extra_classpath = node[:druid][node_type]["druid.extra_classpath"] || node[:druid]["druid.extra_classpath"]
  template "/etc/init/#{service_name}.conf" do
    source "upstart.conf.erb"
    variables({
                  :node_type => node_type,
                  :user => node[:druid][:user],
                  :group => node[:druid][:group],
                  :type_specific_config_dir => type_specific_config_dir,
                  :common_config_dir => common_config_dir,
                  :install_dir => node[:druid][:install_dir],
                  :java_opts => node[:druid][node_type][:java_opts] || node[:druid][:java_opts],
                  :timezone => node[:druid][:timezone],
                  :encoding => node[:druid][:encoding],
                  :command_suffix => node[:druid][:log_to_syslog].to_s == "1" ? "2>&1 | logger -t #{service_name}" : "",
                  :port => type_specific_props["druid.port"],
                  :extra_classpath => (extra_classpath.nil? || extra_classpath.empty?) ? "" : "#{extra_classpath}:"
              })
  end

  service "druid-#{node_type}" do
    provider Chef::Provider::Service::Upstart
    supports :restart => true, :start => true, :stop => true
    action [:enable, :restart]
  end
end
