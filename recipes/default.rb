
execute 'apt-get update'

include_recipe "build-essential"
include_recipe "git"
include_recipe "cron"

software_dir = node['caffe']['software_dir']
local_user   = node['caffe']['local_user']
local_group  = node['caffe']['local_group']

directory software_dir do
  owner local_user
  group local_group
end

# linux headers
package "linux-headers-#{node['os_version']}"
# https://forums.aws.amazon.com/thread.jspa?messageID=558414
package "linux-image-#{node['os_version']}"
# http://stackoverflow.com/a/26525293
package "linux-image-extra-#{node['os_version']}"

# caffe dependencies
%w{ libprotobuf-dev libleveldb-dev libsnappy-dev libopencv-dev
    libboost-all-dev libhdf5-serial-dev protobuf-compiler gcc-4.6
    g++-4.6 gcc-4.6-multilib g++-4.6-multilib gfortran libjpeg62
    libfreeimage-dev libatlas-base-dev git python-dev python-pip
    libgflags-dev libgoogle-glog-dev liblmdb-dev }.each do |p|
  package p
end

# install cuda
remote_file "#{software_dir}/cuda-repo-ubuntu1404_7.5-18_amd64" do
  source "http://developer.download.nvidia.com/compute/cuda/repos/ubuntu1404/x86_64/cuda-repo-ubuntu1404_7.5-18_amd64.deb"
  action :create_if_missing
  notifies :run, 'bash[install-cuda-repo]', :immediately
  owner local_user
  group local_group
end
bash 'install-cuda-repo' do
  action :nothing
  code "dpkg -i #{software_dir}/cuda-repo-ubuntu1404_7.5-18_amd64"
  notifies :run, 'execute[apt-get update]', :immediately
end
# https://bugs.launchpad.net/ubuntu/+source/nvidia-graphics-drivers-331/+bug/1401390
# package 'cuda'
execute 'install-cuda' do
  command "apt-get -q -y install --no-install-recommends cuda"
end

cudnn_filename = "#{node['caffe']['cudnn_tarball_name_wo_tgz']}.tgz"
if File.exists? "#{File.dirname(__FILE__)}/../files/default/cudnn-tarball/#{cudnn_filename}"
  cookbook_file "#{software_dir}/#{cudnn_filename}" do
    source "cudnn-tarball/#{cudnn_filename}"
    mode 0644
    owner local_user
    group local_group
  end
  execute "tar -zxf #{cudnn_filename}" do
    cwd software_dir
    not_if { FileTest.exists? "#{software_dir}/#{node['caffe']['cudnn_tarball_name_wo_tgz']}" }
    user local_user
    group local_group
  end
  execute 'cp cudnn.h /usr/local/include' do
    cwd "#{software_dir}/cuda/include"
    not_if { FileTest.exists? "/usr/local/include/cudnn.h" }
  end
  [ 'libcudnn_static.a', 'libcudnn.so.7.0.64' ].each do |lib|
    execute "cp #{lib} /usr/local/lib" do
    cwd "#{software_dir}/cuda/lib64"
      not_if { FileTest.exists? "/usr/local/lib/#{lib}" }
    end
  end
  link "/usr/local/lib/libcudnn.so.7.0" do
    to "/usr/local/lib/libcudnn.so.7.0.64"
  end
  link "/usr/local/lib/libcudnn.so" do
    to "/usr/local/lib/libcudnn.so.7.0"
  end
  cudnn_installed = true
end

# set up LD_LIBRARY_PATH
file "/etc/ld.so.conf.d/caffe.conf" do
  owner "root"
  group "root"
  content "/usr/local/cuda-7.5/targets/x86_64-linux/lib"
  notifies :run, 'execute[ldconfig]', :immediately
end
execute 'ldconfig' do
  action :nothing
end

# download caffe and setup initial Makefile.config
git "#{software_dir}/caffe" do
  repository "https://github.com/BVLC/caffe.git"
  revision "6eae122a8eb84f8371dde815986cd7524fc4cbaa" # 1 October 2015
  action :sync
  user local_user
  group local_group
end
template "#{software_dir}/caffe/Makefile.config" do
  source "Makefile.config.erb"
  mode 0644
  owner local_user
  group local_group
  variables({
      :cudnn_installed => cudnn_installed
  })
end

# install python requirements
execute 'install-python-reqs' do
  cwd "#{software_dir}/caffe/python"
  command "(for req in $(cat requirements.txt); do pip install $req; done) && touch /home/#{local_user}/.caffe-python-reqs-installed && chown #{local_user}:#{local_group} /home/#{local_user}/.caffe-python-reqs-installed"
  creates "/home/#{local_user}/.caffe-python-reqs-installed"
end

# make caffe!
execute 'build-caffe' do
  cwd "#{software_dir}/caffe"
  command "make all -j8 "
  creates "#{software_dir}/caffe/build"
  user local_user
  group local_group
  notifies :run, 'execute[build-caffe-tests]', :immediately
end
execute 'build-caffe-tests' do
  cwd "#{software_dir}/caffe"
  command "make test -j8"
  action :nothing
  user local_user
  group local_group
  notifies :run, 'execute[build-caffe-python]', :immediately
end
execute 'build-caffe-python' do
  cwd "#{software_dir}/caffe"
  command "make pycaffe"
  action :nothing
  user local_user
  group local_group
end

# fix warning message 'libdc1394 error: Failed to initialize libdc1394' when running make runtest
# http://stackoverflow.com/a/26028597
# need to set this on each boot since the /dev links are cleared after shutdown
cron_d 'fix-libdc1394-warning' do
  predefined_value '@reboot'
  command 'ln -s /dev/null /dev/raw1394'
end

# set path
magic_shell_environment 'PATH' do
  value "$PATH:#{software_dir}/caffe/build/tools"
end
magic_shell_environment 'PYTHONPATH' do
  value "$PYTHONPATH:#{software_dir}/caffe/python"
end
