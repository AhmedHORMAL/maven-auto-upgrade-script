#!/usr/bin/env bash
#
#UsageStart
#
# Usage: $0 <https://github.com/account/repository.git|git directory> [<target branch>]
#
#UsageEnd

#Change current directory to the script one
cd $( dirname "${0}")
typeset -r scriptDir="${PWD}"
#Source git function library
source "${scriptDir}/lib/git-lib.sh"

#Main

#Environment check
environmentCheck
if [[ "${?}" -ne 0 ]]
then
	exit 1
fi

#Arguments checking
if [[ "${#}" -lt 1 || "${#}" -gt 2 ]]
then
	usage
	exit 1

#help display
elif [[ "${1}" = "-h" || "${1}" = "help" || "${1}" = "--help" ]]
then
	usage
	exit 0
fi

#Argument mapping
declare -r gitRepository="${1}"
declare -r gitBranch="${2:-master}"

if [[ "${gitRepository}" = http://* || "${gitRepository}" = https://* || "${gitRepository}" = ssh://* || "${gitRepository}" = *@* ]]
then
	declare -r cloneDirectory=$( basename "${gitRepository%.git}" )

	#Target clone directory clean up if it exists
	if [[ -e "${cloneDirectory}" ]]
	then
		echo -n "Deleting existing ${PWD}/${cloneDirectory} file-directory:..."
		rmOutput=$( rm -r "${cloneDirectory}" 0<&- 2>&1)
		if [[ "${?}" -ne 0 ]]
		then
			echo -e "[\033[31mFAILED\033[0m]"
			echo "${rmOutput}" >&2
			exit 1
		fi
		echo -e "[\033[32mOK\033[0m]"
	fi

	#Clone the target git repository
	echo -n "Cloning $(echo ${gitRepository} | sed -e 's|https*://[^/]*/||' -e 's/.git$//' ) repository:..."
	cloneOutput=$( git clone --depth 1 --branch "${gitBranch}" "${gitRepository}" "${cloneDirectory}" 2>&1 )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${cloneOutput}" >&2
		exit 1
	fi

	cd "${cloneDirectory}" 2>/dev/null
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "Cannot go into ${cloneDirectory} git clone directory" >&2
		exit 1
	fi
	echo -e "[\033[32mOK\033[0m]"

else
	declare -r cloneDirectory="${gitRepository}"

	#Go into the target directory
	echo -n "Use target ${cloneDirectory} git repository:..."
	cd "${cloneDirectory}" 2>/dev/null
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "Cannot go into ${cloneDirectory} git directory" >&2
		exit 1
	fi
	echo -e "[\033[32mOK\033[0m]"

	#Checkout the target branch (default: master)
	echo -n "Checkout of main branch ${gitBranch} on the ${gitRepository} git repository:..."
	checkoutReturn=$( git checkout "${gitBranch}" 2>&1 )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${checkoutReturn}" >&2
		exit 1
	fi
	echo -e "[\033[32mOK\033[0m]"

	#Refresh the target git directory
	echo -n "Refresh ${gitRepository} git repository:..."
	cloneOutput=$( git pull 2>&1 )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${cloneOutput}" >&2
		exit 1
	fi
	echo -e "[\033[32mOK\033[0m]"
fi


#Checking new component versions with Maven
echo -n "Checking property version upgrades:..."
versionOutput=$( mvn -U versions:display-plugin-updates  versions:display-property-updates 2>&1 )
if [[ "${?}" -ne 0 ]]
then
	echo -e "[\033[31mFAILED\033[0m]"
	echo "${versionOutput}" >&2
	exit 1
fi
declare -ri countUpgrade=$( echo "${versionOutput}" | grep -- "->" | grep '${' | wc -l )
echo -e "[\033[32mOK\033[0m] -> ${countUpgrade} upgrade(s) found"

typeset -i scriptReturnCode=0

#Loop on each property that can be upgraded
while read line
do
	declare property=$( echo "${line}" | awk '{print $2}' | sed -e 's/^${//' -e 's/}$//' )
	declare versionDelta=$( echo "${line}" | awk '{ print $(NF-2),$(NF-1),$NF }' )

	echo -e "\nUpgrading ${property} property from $( echo ${versionDelta} | sed 's/->/to/' )"

	#Get back to the pull-request target branch (default: master)
	echo -n "Checkout of main branch ${gitBranch}:..."
	checkoutReturn=$( git checkout "${gitBranch}" 2>&1 )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${checkoutReturn}" >&2
		scriptReturnCode=1
		continue
	fi
	echo -e "[\033[32mOK\033[0m]"

	#Check the existance of the remote branch before
	declare targetbranchUpgrade="${property}_upgrade_"$( echo "${versionDelta}" | sed -e 's/ -> /_to_/g' )
	echo -n "Checking existence of the remote branch ${targetbranchUpgrade}:..."
	git ls-remote --heads 2>&1 | grep --silent "/${targetbranchUpgrade}$"
	if [[ "${?}" -eq 0 ]]
	then
		echo -e "[\033[33mALREADY EXISTS\033[0m] -> skipping this upgrade"
		continue
	fi
	echo -e "[\033[32mOK\033[0m]"

	#Do the dependency/plugin upgrade by changing its property with Maven
	echo -n "Modifying property ${property}:..."
	updateOutput=$( mvn -U versions:update-property -Dproperty="${property}" 2>&1 )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${updateOutput}" >&2
		scriptReturnCode=1
		continue
	fi
	echo -e "[\033[32mOK\033[0m]"

	#Create and checkout a new branch for the property upgrade
	declare branchVersionUpgrade=$( echo "${updateOutput}" | grep '^\[INFO\] Updated ${'"${property}"'}' | grep -o "[^ ]* to [^ ]*$" | sed 's/ /_/g' )
	echo -n "Create and checkout branch ${property}_upgrade_${branchVersionUpgrade}:..."
	checkoutReturn=$( git checkout --track -b "${property}_upgrade_${branchVersionUpgrade}" 2>&1 )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${checkoutReturn}" >&2
		scriptReturnCode=1
		continue
	fi
	echo -e "[\033[32mOK\033[0m]"

	#Add modified pom files to staged files for the commit
	echo -n "Adding modified pom.xml to commit files:..."
	gitAddReturn=$( git add -u )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${gitAddReturn}" >&2
		scriptReturnCode=1
		continue
	fi
	echo -e "[\033[32mOK\033[0m]"

	#Commit the modified pom files
	echo -n "Commiting modified pom.xml files:..."
	gitCommitReturn=$( git commit -m "$(commitMessage "${property}" "${updateOutput}")" -m "$(commitDetails "${property}" "${updateOutput}")" 2>&1 )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${gitCommitReturn}" >&2
		scriptReturnCode=1
		continue
	fi
	echo -e "[\033[32mOK\033[0m]"

	#Push the commit to the git repository
	echo -n "Pushing the commit to the git repository:..."
	gitPushReturn=$( git push origin "${property}_upgrade_${branchVersionUpgrade}" 2>&1 )
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${gitPushReturn}" >&2
		scriptReturnCode=1
		continue
	fi
	echo -e "[\033[32mOK\033[0m]"

	#The pull-request can bea created only if GitHub hub command is installed
	if [[ ! -z "${hubCommand}" ]]
	then
		declare version=$( echo "${updateOutput}" | grep '^\[INFO\] Updated ${'"${property}"'}' | grep -o "[^ ]* to [^ ]*$" | sed 's/to/->/' )

		#Create the pull-request from the created branch on the main git branch
		echo -n "Creating the associated GitHub pull-request:..."
		hubPullRequestReturn=$( ${hubCommand} pull-request  -m "${property} upgrade ${version}" -b "${gitBranch}" -h "${property}_upgrade_${branchVersionUpgrade}" 2>&1 )
		if [[ "${?}" -ne 0 ]]
		then
			echo -e "[\033[31mFAILED\033[0m]"
			echo "${hubPullRequestReturn}" >&2
			scriptReturnCode=1
			continue
		fi
		echo -e "[\033[32mOK\033[0m] -> ${hubPullRequestReturn}"
	else
		echo "Creating the associated GitHub pull-request:...[[\033[33mGitHub hub command not installed or found\033[0m]"
	fi
done < <( echo "${versionOutput}" | grep -- "->" | grep '${' )

#Clone directory clean up if no error occurs and if it's a temporary clone
if [[ "${scriptReturnCode}" -eq 0 && "${gitRepository}" = http* ]]
then
	#Return to the script directory
	echo -n "Deleting clone ${scriptDir}/${cloneDirectory} directory:..."
	cd "${scriptDir}"
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "Cannot return into ${scriptDir} script directory" >&2
		exit 1
	fi

	#Delete the clone directory
	rmOutput=$( rm -r "${cloneDirectory}" 0<&- 2>&1)
	if [[ "${?}" -ne 0 ]]
	then
		echo -e "[\033[31mFAILED\033[0m]"
		echo "${rmOutput}" >&2
		exit 1
	fi
	echo -e "[\033[32mOK\033[0m]"
fi

exit "${scriptReturnCode}"
