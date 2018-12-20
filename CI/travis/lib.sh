#!/bin/sh -xe

export TRAVIS_API_URL="https://api.travis-ci.org"

COMMON_SCRIPTS="jobs_running_cnt.py inside_docker.sh"

get_script_path() {
	local script="$1"

	[ -n "$script" ] || return 1

	if [ -f "CI/travis/$script" ] ; then
		echo "CI/travis/$script"
	elif [ -f "build/$script" ] ; then
		echo "build/$script"
	else
		return 1
	fi
}

pipeline_branch() {
	local branch=$1

	[ -n "$branch" ] || return 1

	# master is a always a pipeline branch
	[ "$branch" = "master" ] && return 0

	# Turn off tracing for a while ; log can fill up here
	set +x
	# Check if branch name is 20XX_RY where:
	#   XX - 14 to 99 /* wooh, that's a lot of years */
	#   Y  - 1 to 9   /* wooh, that's a lot of releases per year */
	for year in $(seq 2014 2099) ; do
		for rel_num in $(seq 1 9) ; do
			[ "$branch" = "${year}_R${rel_num}" ] && \
				return 0
		done
	done
	set -x

	return 1
}

should_trigger_next_builds() {
	local branch="$1"

	[ -z "${COVERITY_SCAN_PROJECT_NAME}" ] || return 1

	# These Travis-CI vars have to be non-empty
	[ -n "$TRAVIS_PULL_REQUEST" ] || return 1
	[ -n "$branch" ] || return 1
	set +x
	[ -n "$TRAVIS_API_TOKEN" ] || return 1
	set -x

	# Has to be a non-pull-request
	[ "$TRAVIS_PULL_REQUEST" = "false" ] || return 1

	pipeline_branch "$branch" || return 1

	local python_script="$(get_script_path jobs_running_cnt.py)"
	if [ -z "$python_script" ] ; then
		echo "Could not find 'jobs_running_cnt.py'"
		return 1
	fi

	local jobs_cnt=$(python $python_script)

	# Trigger next job if we are the last job running
	[ "$jobs_cnt" = "1" ]
}

trigger_build() {
	local repo_slug="$1"
	local branch="$2"

	[ -n "$repo_slug" ] || return 1
	[ -n "$branch" ] || return 1

	local body="{
		\"request\": {
			\"branch\":\"$branch\"
		}
	}"

	# Turn off tracing here (shortly)
	set +x
	curl -s -X POST \
		-H "Content-Type: application/json" \
		-H "Accept: application/json" \
		-H "Travis-API-Version: 3" \
		-H "Authorization: token $TRAVIS_API_TOKEN" \
		-d "$body" \
		https://api.travis-ci.org/repo/$repo_slug/requests
	set -x
}

trigger_adi_build() {
	local adi_repo="$1"
	local branch="$2"

	[ -n "$adi_repo" ] || return 1
	trigger_build "analogdevicesinc%2F$adi_repo" "$branch"
}

command_exists() {
	local cmd=$1
	[ -n "$cmd" ] || return 1
	type "$cmd" >/dev/null 2>&1
}

get_ldist() {
	case "$(uname)" in
	Linux*)
		if [ ! -f /etc/os-release ] ; then
			if [ -f /etc/centos-release ] ; then
				echo "centos-$(sed -e 's/CentOS release //' -e 's/(.*)$//' \
					-e 's/ //g' /etc/centos-release)-$(uname -m)"
				return 0
			fi
			ls /etc/*elease
			[ -z "${OSTYPE}" ] || {
				echo "${OSTYPE}-unknown"
				return 0
			}
			echo "linux-unknown"
			return 0
		fi
		. /etc/os-release
		if ! command_exists dpkg ; then
			echo $ID-$VERSION_ID-$(uname -m)
		else
			echo $ID-$VERSION_ID-$(dpkg --print-architecture)
		fi
		;;
	Darwin*)
		echo "darwin-$(sw_vers -productVersion)"
		;;
	*)
		echo "$(uname)-unknown"
		;;
	esac
	return 0
}

__brew_install_or_upgrade() {
	brew install $1 || \
		brew upgrade $1 || \
		brew ls --version $1
}

brew_install_or_upgrade() {
	while [ -n "$1" ] ; do
		__brew_install_or_upgrade "$1" || return 1
		shift
	done
}

upload_file_to_swdownloads() {

	if [ "$#" -ne 4 ] ; then
		echo "skipping deployment of something"
		echo "send called with $@"
		return 0
	fi

	local LIBNAME=$1
	local FROM=$2
	local FNAME=$3
	local EXT=$4

	if [ -z "$FROM" ] ; then
		echo no file to send
		return 1
	fi

	if [ ! -r "$FROM" ] ; then
		echo "file $FROM is not readable"
		return 1
	fi

	if [ -n "$TRAVIS_PULL_REQUEST_BRANCH" ] ; then
		local branch="$TRAVIS_PULL_REQUEST_BRANCH"
	else
		local branch="$TRAVIS_BRANCH"
	fi

	local TO=${branch}_${FNAME}
	local LATE=${branch}_latest_${LIBNAME}${LDIST}${EXT}
	local GLOB=${DEPLOY_TO}/${branch}_${LIBNAME}-*

	echo attemting to deploy $FROM to $TO
	echo and ${branch}_${LIBNAME}${LDIST}${EXT}
	ssh -V

	if curl -m 10 -s -I -f -o /dev/null http://swdownloads.analog.com/cse/travis_builds/${TO} ; then
		local RM_TO="rm ${TO}"
	fi

	if curl -m 10 -s -I -f -o /dev/null http://swdownloads.analog.com/cse/travis_builds/${LATE} ; then
		local RM_LATE="rm ${LATE}"
	fi

	sftp ${EXTRA_SSH} ${SSHUSER}@${SSHHOST} <<-EOF
		cd ${DEPLOY_TO}

		${RM_TO}
		put ${FROM} ${TO}
		ls -l ${TO}

		${RM_LATE}
		symlink ${TO} ${LATE}
		ls -l ${LATE}
		bye
	EOF
	[ "$?" = "0" ] || return 1

	# limit things to a few files, so things don't grow forever
	if [ "${EXT}" = ".deb" ] ; then
		for files in $(ssh ${EXTRA_SSH} ${SSHUSER}@${SSHHOST} \
			"ls -lt ${GLOB}" | tail -n +100 | awk '{print $NF}')
		do
			ssh ${EXTRA_SSH} ${SSHUSER}@${SSHHOST} \
				"rm ${DEPLOY_TO}/${files}" || \
				return 1
		done
	fi

	return 0
}

prepare_docker_image() {
	local DOCKER_IMAGE="$1"
	sudo apt-get -qq update
	echo 'DOCKER_OPTS="-H tcp://127.0.0.1:2375 -H unix:///var/run/docker.sock -s devicemapper"' | sudo tee /etc/default/docker > /dev/null
	sudo service docker restart
	sudo docker pull "$DOCKER_IMAGE"
}

run_docker_script() {
	local DOCKER_SCRIPT="$(get_script_path $1)"
	local DOCKER_IMAGE="$2"
	local OS_TYPE="$3"
	local MOUNTPOINT="${4:-docker_build_dir}"
	sudo docker run --rm=true \
		-v "$(pwd):/${MOUNTPOINT}:rw" \
		$DOCKER_IMAGE \
		/bin/bash -xe "/${MOUNTPOINT}/${DOCKER_SCRIPT}" "${MOUNTPOINT}" "${OS_TYPE}"
}

ensure_wget() {
	! command_exists wget || return 0
	if command_exists apt-get ; then
		apt-get install -y wget
		return 0
	fi
	if command_exists yum ; then
		yum install -y wget
		return 0
	fi
}

# Other scripts will download lib.sh [this script] and lib.sh will
# in turn download the other scripts it needs.
# This gives way more flexibility when changing things, as they propagate
for script in $COMMON_SCRIPTS ; do
	[ ! -f "CI/travis/$script" ] || continue
	[ ! -f "build/$script" ] || continue
	mkdir -p build
	ensure_wget
	wget https://raw.githubusercontent.com/analogdevicesinc/libiio/master/CI/travis/$script \
		-O build/$script
done
