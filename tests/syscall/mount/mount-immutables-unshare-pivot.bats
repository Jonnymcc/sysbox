#!/usr/bin/env bats

#
# Verify trapping & emulation on "mount" and "unmount2" syscalls
#

load ../../helpers/run
load ../../helpers/syscall
load ../../helpers/docker
load ../../helpers/environment
load ../../helpers/mounts
load ../../helpers/sysbox-health


function teardown() {
  sysbox_log_check
}

# Test to verify immutable mounts within a sys container's unshare(mnt) +
# pivot() context.
#
# Note: a sys container immutable mount is a mount that is setup at container
# creation time.
#

chrootpath="/tmp/chrootdir"
immutable_ro_dir="ro_dir"
immutable_ro_file="ro_file"
immutable_masked_dir="masked_dir"
immutable_masked_file="masked_file"

immutable_ro_dir_path="${chrootpath}/${immutable_ro_dir}"
immutable_ro_file_path="${chrootpath}/${immutable_ro_file}"
immutable_masked_dir_path="${chrootpath}/${immutable_masked_dir}"
immutable_masked_file_path="${chrootpath}/${immutable_masked_file}"

function local_rootfs_prepare() {
  mkdir -p ${immutable_ro_dir_path}
  touch ${immutable_ro_file_path}
  mkdir -p ${immutable_masked_dir_path}
  touch ${immutable_masked_file_path}
}

# Testcase #1.
#
# Ensure that inner-container mountpoints associated to immutable mountpoints in
# a sys-container, *can* always be unmounted regardless of the sysbox-fs'
# allow-immutable-remounts settings.
@test "immutable mount *can* be unmounted -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_mounts=$(list_container_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_mounts}
  [ "$status" -ne 0 ]
  # Reverse-sort immutable-list to avoid dependency issues (e.g. "/dev/" can't be
  # unmounted before "/dev/mqueue").
  immutable_mounts=$(echo ${immutable_mounts} | tr ' ' '\n' | sort -r | tr '\n' ' ')

  for m in ${immutable_mounts}; do
    # Skip /proc and /sys since these are special mounts (we have dedicated
    # tests that cover unmounting ops); /dev/null on the other can't be unmounted
    # as it's being used as entrypoint.
    if [[ ${m} =~ "/proc" ]] || [[ ${m} =~ "/proc/*" ]] ||
        [[ ${m} =~ "/sys" ]] || [[ ${m} =~ "/sys/*" ]] ||
        [[ ${m} == "/dev" ]] || [[ ${m} == "/dev/null" ]]; then
        continue
    fi

    printf "\ntesting unmount of immutable mount ${m}\n"

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]
  done

  docker_stop ${syscont}
}

# Testcase #2.
#
# Ensure that inner-container mountpoints associated to read-only immutable
# mountpoints in a sys-container, can't be remounted as read-write if, and only
# if, sysbox-fs is running with 'allow-immutable-remounts' option disabled.
@test "immutable ro mount can't be remounted rw -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_ro_mounts=$(list_container_ro_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_ro_mounts}
  [ "$status" -ne 0 ]

  # Determine the mode in which to operate.
  local remounts_allowed
  run allow_immutable_remounts
  if [ "${status}" -eq 0 ]; then
    remounts_allowed=0
  else
    remounts_allowed=1
  fi

  for m in ${immutable_ro_mounts}; do
    printf "\ntesting rw remount of immutable ro mount ${m}\n"

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o remount,bind,rw ${m}\""
    if [[ ${remounts_allowed} -eq 0 ]]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -ne 0 ]
    fi
  done

  local immutable_ro_mounts_after=$(list_container_ro_mounts ${syscont} ${inner_pid} "/")
  if [[ ${remounts_allowed} -eq 0 ]]; then
    [[ ${immutable_ro_mounts} != ${immutable_ro_mounts_after} ]]
  else
    [[ ${immutable_ro_mounts} == ${immutable_ro_mounts_after} ]]
  fi

  docker_stop ${syscont}
}

# Testcase #3.
#
# Ensure that inner-container mountpoints associated to read-write immutable
# mountpoints in a sys-container, *can* be remounted as read-only, and then
# back to read-write.
@test "immutable rw mount can be remounted ro -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_rw_mounts=$(list_container_rw_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_rw_mounts}
  [ "$status" -ne 0 ]  

  for m in ${immutable_rw_mounts}; do

    # Remounting /proc or /dev as read-only will prevent docker execs into the
    # container; skip these.
    if [[ ${m} =~ "/proc" ]] || [[ ${m} =~ "/proc/*" ]] ||
       [[ ${m} =~ "/dev" ]] || [[ ${m} =~ "/dev/*" ]]; then
      continue
    fi

    printf "\ntesting ro remount of immutable rw mount ${m}\n"

    docker exec ${syscont} sh -c \
      "docker exec inner sh -c \"mount -o remount,bind,ro ${m}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c \
      "docker exec inner sh -c \"mount -o remount,bind,rw ${m}\""
    [ "$status" -eq 0 ]
  done

  docker_stop ${syscont}
}

# Testcase #4.
#
# Ensure that inner-container mountpoints associated to read-only immutable
# mountpoints in a sys-container, *can* always be remounted as read-only.
@test "immutable ro mount can be remounted ro -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_ro_mounts=$(list_container_ro_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_ro_mounts}
  [ "$status" -ne 0 ]

  for m in ${immutable_ro_mounts}; do
    printf "\ntesting ro remount of immutable ro mount ${m}\n"

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o remount,bind,ro ${m}\""
    [ "$status" -eq 0 ]
  done

  local immutable_ro_mounts_after=$(list_container_ro_mounts ${syscont} ${inner_pid} "/")
  [[ ${immutable_ro_mounts} == ${immutable_ro_mounts_after} ]]

  docker_stop ${syscont}
}

# Testcase #5.
#
# Ensure that inner-container mountpoints associated to read-write immutable
# mountpoints in a sys-container, *can* always be remounted as read-write.
@test "immutable rw mount can be remounted rw -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_rw_mounts=$(list_container_rw_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_rw_mounts}
  [ "$status" -ne 0 ]  

  for m in ${immutable_rw_mounts}; do
    printf "\ntesting rw remount of immutable rw mount ${m}\n"

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o remount,bind,rw ${m}\""
    [ "$status" -eq 0 ]
  done

  local immutable_rw_mounts_after=$(list_container_rw_mounts ${syscont} ${inner_pid} "/")
  [[ ${immutable_rw_mounts} == ${immutable_rw_mounts_after} ]]

  docker_stop ${syscont}
}

# Testcase #6.
#
# Ensure that inner-container mountpoints associated to read-only immutable
# mountpoints in a sys-container, can be bind-mounted to a new mountpoint, but
# not re-mounted read-write at the new mountpoint if, and only if, sysbox-fs is
# running with 'allow-immutable-remounts' knob disabled. Alternatively, allow
# remounts to succeed.
@test "immutable ro mount can't be bind-mounted rw -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_ro_mounts=$(list_container_ro_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_ro_mounts}
  [ "$status" -ne 0 ]  
  local target="/root/target"

  # Determine the mode in which to operate.
  local remounts_allowed
  run allow_immutable_remounts
  if [ "${status}" -eq 0 ]; then
    remounts_allowed=0
  else
    remounts_allowed=1
  fi

  for m in ${immutable_ro_mounts}; do

    printf "\ntesting bind-mount of immutable ro mount ${m}\n"

    # Create bind-mount target (dir or file, depending on bind-mount source type)
    docker exec ${syscont} bash -c "[[ -d ${m} ]]"

    if [ "$status" -eq 0 ]; then
      docker exec ${syscont} sh -c "docker exec inner sh -c \"mkdir -p ${target}\""
      [ "$status" -eq 0 ]
    else
      docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${target}\""
      [ "$status" -eq 0 ]
    fi

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount --bind ${m} ${target}\""
    [ "$status" -eq 0 ]

    # Verify the bind-mount continues to be read-only
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${target}\""
    [ "$status" -ne 0 ]

    # This rw remount should fail if 'allow-immutable-remounts' knob is disabled
    # (default behavior).
    printf "\ntesting rw remount of immutable ro bind-mount ${target}\n"
    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o remount,bind,rw ${target}\""
    if [[ ${remounts_allowed} -eq 0 ]]; then
      [ "$status" -eq 0 ]
    else
      [ "$status" -ne 0 ]
    fi

    # This ro remount should pass (it's not needed but just to double-check)
    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o remount,bind,ro ${target}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${target}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"rm -rf ${target}\""
    [ "$status" -eq 0 ]
  done

  docker_stop ${syscont}
}

# Testcase #7.
#
# Ensure that inner-container mountpoints associated to read-write immutable
# mountpoints in a sys-container, can be bind-mounted to a new mountpoint, and
# then remounted read-only.
@test "immutable rw mount can be bind-mounted ro -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_rw_mounts=$(list_container_rw_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_rw_mounts}
  [ "$status" -ne 0 ]  
  local target="/root/target"

  for m in ${immutable_rw_mounts}; do

    # skip /proc and /sys since these are special mounts (we have dedicated
    # tests for remounting them). We also
    if [[ ${m} =~ "/proc" ]] || [[ ${m} =~ "/proc/*" ]] ||
       [[ ${m} =~ "/sys" ]] || [[ ${m} =~ "/sys/*" ]] ||
       [[ ${m} =~ "/dev" ]] || [[ ${m} =~ "/dev/*" ]]; then
      continue
    fi

    printf "\ntesting bind-mount of immutable rw mount ${m}\n"

    # Create bind-mount target (dir or file, depending on bind-mount source type)
    docker exec ${syscont} bash -c "[[ -d ${m} ]]"

    if [ "$status" -eq 0 ]; then
      docker exec ${syscont} sh -c "docker exec inner sh -c \"mkdir -p ${target}\""
      [ "$status" -eq 0 ]
    else
      docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${target}\""
      [ "$status" -eq 0 ]
    fi

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount --bind ${m} ${target}\""
    [ "$status" -eq 0 ]

    # Verify the bind-mount continues to be read-write
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${target}\""
    [ "$status" -eq 0 ]

    # This ro remount should pass
    printf "\ntesting ro remount of immutable rw bind-mount ${target}\n"
    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o remount,bind,ro ${target}\""
    [ "$status" -eq 0 ]

    # Verify the bind-mount is now read-only
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${target}\""
    [ "$status" -ne 0 ]

    # Verify the bind-mount source continues to be read-write
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${m}\""
    [ "$status" -eq 0 ]

    # This rw remount should also pass
    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o remount,bind,rw ${target}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${target}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"rm -rf ${target}\""
    [ "$status" -eq 0 ]
  done

  docker_stop ${syscont}
}

# Testcase #8.
#
# Ensure that inner-container mountpoints associated to read-only immutable
# mountpoints in a sys-container, can be masked by a new read-write mount on
# top of it.
@test "rw mount on top of immutable ro mount -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_ro_mounts=$(list_container_ro_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_ro_mounts}
  [ "$status" -ne 0 ]  

  for m in ${immutable_ro_mounts}; do

    # skip /proc and /sys since these are special mounts (we have dedicated
    # tests for remounting them). We also
    if [[ ${m} =~ "/proc" ]] || [[ ${m} =~ "/proc/*" ]] ||
         [[ ${m} =~ "/sys" ]] || [[ ${m} =~ "/sys/*" ]] ||
         [[ ${m} =~ "/dev" ]] || [[ ${m} =~ "/dev/*" ]]; then
      continue
    fi

    # Skip directory mountpoints.
    docker exec ${syscont} sh -c "docker exec inner bash -c \"[[ ! -d ${m} ]]\""
    if [ "$status" -eq 0 ]; then
      continue
    fi

    # This should fail (mount is read-only)
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${m}\""
    [ "$status" -ne 0 ]

    printf "\nmounting tmpfs (rw) on top of immutable ro mount ${m}\n"

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -t tmpfs -o size=100M tmpfs ${m}\""
    [ "$status" -eq 0 ]

    # This should pass (tmpfs mount is read-write)
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${m}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]

    # This should fail (mount is read-only)
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${m}\""
    [ "$status" -ne 0 ]
  done

  docker_stop ${syscont}
}

# Testcase #9.
#
# Ensure that inner-container mountpoints associated to read-write immutable
# mountpoints in a sys-container, can be masked by a new read-only mount on
# top of it.
@test "ro mount on top of immutable rw mount -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_rw_mounts=$(list_container_rw_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_rw_mounts}
  [ "$status" -ne 0 ]  

  for m in ${immutable_rw_mounts}; do

    # skip /proc and /sys since these are special mounts (we have dedicated
    # tests for remounting them). We also
    if [[ ${m} =~ "/proc" ]] || [[ ${m} =~ "/proc/*" ]] ||
         [[ ${m} =~ "/sys" ]] || [[ ${m} =~ "/sys/*" ]] ||
         [[ ${m} =~ "/dev" ]] || [[ ${m} =~ "/dev/*" ]]; then
      continue
    fi

    # Skip file mountpoints.
    docker exec ${syscont} sh -c "docker exec inner bash -c \"[[ ! -d ${m} ]]\""
    if [ "$status" -eq 0 ]; then
      continue
    fi

    # This should pass (mount is read-write)
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${m}\""
    [ "$status" -eq 0 ]

    printf "\nmounting tmpfs (ro) on top of immutable rw mount ${m}\n"

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -t tmpfs -o ro,size=100M tmpfs ${m}\""
    [ "$status" -eq 0 ]

    # This should fail (tmpfs mount is read-only)
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${m}\""
    [ "$status" -ne 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]

    # This should pass (mount is read-write)
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${m}\""
    [ "$status" -eq 0 ]
  done

  docker_stop ${syscont}
}

# Testcase #10.
#
# Ensure proper execution of unmount ops over mount-stacks and bind-mount chains
# formed by regular files mountpoints.
@test "unmount chain of file bind-mounts -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_mounts=$(list_container_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_mounts}
  [ "$status" -ne 0 ]  

  for m in ${immutable_mounts}; do
    # Skip /proc and /sys since these are special mounts (we have dedicated
    # tests that cover unmounting ops).
    if [[ ${m} =~ "/proc" ]] || [[ ${m} =~ "/proc/*" ]] ||
        [[ ${m} =~ "/sys" ]] || [[ ${m} =~ "/sys/*" ]] ||
        [[ ${m} =~ "/dev" ]] || [[ ${m} =~ "/dev/*" ]]; then
      continue
    fi

    # Skip non-file mountpoints.
    docker exec ${syscont} sh -c "docker exec inner bash -c \"[[ ! -f ${m} ]]\""
    if [ "$status" -eq 0 ]; then
      continue
    fi

    # Create mount-stack and verify that the last two element can be always
    # unmounted.
    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o bind /dev/null ${m}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o bind /dev/null ${m}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]    

    # Create bind-mount chain and verify that all the unmounts are allowed.
    docker exec ${syscont} sh -c "docker exec inner sh -c \"touch ${m}2 ${m}3\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o bind ${m} ${m}2\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o bind ${m}2 ${m}3\""
    [ "$status" -eq 0 ]    

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}3\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}2\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]
  done

  docker_stop ${syscont}
}

# Testcase #11.
#
# Ensure proper execution of unmount ops over mount-stacks and bind-mount chains
# formed by directory mountpoints.
@test "unmount chain of dir bind-mounts -- unshare(mnt) + pivot()" {

  local_rootfs_prepare

  local syscont=$(docker_run --rm -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu-bionic-docker-dbg tail -f /dev/null)

  docker exec -d ${syscont} sh -c "dockerd > /var/log/dockerd.log 2>&1"
  [ "$status" -eq 0 ]

  wait_for_inner_dockerd ${syscont}

  docker exec ${syscont} sh -c "docker run --privileged -d --name inner -v ${immutable_ro_dir_path}:${immutable_ro_dir_path}:ro -v ${immutable_ro_file_path}:${immutable_ro_file_path}:ro --mount type=tmpfs,destination=${immutable_masked_dir_path} -v /dev/null:${immutable_masked_file_path} ${CTR_IMG_REPO}/ubuntu:latest tail -f /dev/null"
  [ "$status" -eq 0 ]
  docker exec ${syscont} sh -c "docker inspect --format='{{.State.Pid}}' inner"
  [ "$status" -eq 0 ]
  local inner_pid=$output

  local immutable_mounts=$(list_container_mounts ${syscont} ${inner_pid} "/")
  run is_list_empty ${immutable_mounts}
  [ "$status" -ne 0 ]

  for m in ${immutable_mounts}; do
    # Skip /proc and /sys since these are special mounts (we have dedicated
    # tests that cover unmounting ops).
    if [[ ${m} =~ "/proc" ]] || [[ ${m} =~ "/proc/*" ]] ||
        [[ ${m} =~ "/sys" ]] || [[ ${m} =~ "/sys/*" ]] ||
        [[ ${m} =~ "/dev" ]] || [[ ${m} =~ "/dev/*" ]]; then
      continue
    fi

    # Skip non-dir mountpoints.
    docker exec ${syscont} sh -c "docker exec inner bash -c \"[[ ! -d ${m} ]]\""
    if [ "$status" -eq 0 ]; then
      continue
    fi

    # Create bind-mount chain and verify that all the unmounts are allowed.
    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -t tmpfs -o ro,size=100M tmpfs ${m}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -t tmpfs -o ro,size=100M tmpfs ${m}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]

    # Create bind-mount chain and verify that all the unmounts are allowed.
    docker exec ${syscont} sh -c "docker exec inner sh -c \"mkdir ${m}2 ${m}3\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o bind ${m} ${m}2\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"mount -o bind ${m}2 ${m}3\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}3\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}2\""
    [ "$status" -eq 0 ]

    docker exec ${syscont} sh -c "docker exec inner sh -c \"umount ${m}\""
    [ "$status" -eq 0 ]
  done

  docker_stop ${syscont}
}
