#!/bin/bash
#--------------------------------------------
# 版本：1.0.0
# 功能：
#		1.显示Build Settings 签名配置
#		2.获取git版本数量，并自动更改build号为版本数量号
#		3.日志文本log.txt输出
#		4.自动匹配签名和授权文件
#		5.支持workplace、多个scheme
#		6.校验构建后的ipa的bundle Id、签名、支持最低iOS版本、arm体系等等
#		7.构建前清理缓存,防止xib更改没有被重新编译
#		8.备份历史打包ipa以及log.txt
#		9.可更改OC代码，自动配置服务器测试环境or生产环境
#		10.格式化输出ipa包名称：name_time_开发环境_企业分发_1.0.0(168).ipa
# 作者：
#		fenglh	2016/03/06
# 备注：
#		1.security 命令会报警告,忽略即可:security: SecPolicySetValue: One or more parameters passed to a function were not valid.
#		2.支持Xcode8.0及以上版本（8.0前没有测试过）
#--------------------------------------------
#
# 版本：2.0.0
# 优化：
#		1.去掉可配置签名、授权文件，并修改为自动匹配签名和授权文件！
# 作者：
#		fenglh	2016/03/06
#
#
#--------------------------------------------
#
# 版本：2.0.1
# 优化：
#		为了节省打包时间，在打开发环境的包时，只打armv7
#		profileType==development 时，设置archs=armv7 （向下兼容） ，否则archs为默认值：arm64 和armv7。
# 作者：
#		fenglh	2016/03/06
#

#
# 版本：2.0.2
# 优化：兼容xcode8.3以上版本
# xcode 8.3之后使用-exportFormat导出IPA会报错 xcodebuild: error: invalid option '-exportFormat',改成使用-exportOptionsPlist
# Available options: app-store, ad-hoc, package, enterprise, development, and developer-id.
# 当前用到：app-store ,ad-hoc, enterprise, development
# 作者：
#		fenglh	201708/05

# 版本：2.0.3
# 优化：对授权文件mobiprovision有效期检测，授权文件有效期小于90天，强制打包失败！
#

# 版本：2.0.4
# 优化：默认构建ipa支持armch 为 arm64。（因iOS 11强制禁用32位）
#
#


backupDir=~/Desktop/PackageLog
backupHistoryDir=~/Desktop/PackageLog/history/
tmpLogFile=/tmp/`date +"%Y%m%d%H%M%S"`.txt
plistBuddy="/usr/libexec/PlistBuddy"
xcodebuild="/usr/bin/xcodebuild"
security="/usr/bin/security"
codesign="/usr/bin/codesign"
ruby="/usr/bin/ruby"
lipo="/usr/bin/lipo"
currentShellDir="$( cd "$( dirname "$0"  )" && pwd  )"
##默认分发渠道是内部测试
channel='development'
verbose=true
productionEnvironment=true
debugConfiguration=false
arch='arm64'
declare -a targetNames


##比较版本号大小：大于等于
function versiongreatethen() { test "$(echo "$@" | tr " " "\n" | sort -rn | head -n 1)" == "$1"; }
##初始化配置：bundle identifier 和 code signing identity

function errorExit(){
    endDateSeconds=`date +%s`
    logit "构建时长：$((${endDateSeconds}-${startDateSeconds})) 秒"
    echo -e "\n++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
    echo -e "\033[31m \t打包失败! 原因：$@ \033[0m"
    echo -e "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n"
    exit 1
}

function logit() {
    if [ $verbose == true ]; then
        echo "	>> $@"
    fi
    echo "	>> $@" >> $tmpLogFile
}

function logitVerbose
{
    echo "	>> $@"
    echo "	>> $@" >> $tmpLogFile
}


function profileTypeToName
{
    profileType=$1
    if [[ "$profileType" == 'app-store' ]]; then
        profileTypeName='商店分发'
    elif [[ "$profileType" == 'enterprise' ]]; then
        profileTypeName='企业分发'
    else
        profileTypeName='内部测试'
    fi

}


function initConfiguration() {
	configPlist=$currentShellDir/config.plist
	if [ ! -f "$configPlist" ];then
			errorExit "找不到配置文件：$configPlist"
	fi

	environmentConfigFileName=`$plistBuddy -c 'Print :InterfaceEnvironmentConfig:EnvironmentConfigFileName' $configPlist`
	environmentConfigVariableName=`$plistBuddy -c 'Print :InterfaceEnvironmentConfig:EnvironmentConfigVariableName' $configPlist`
	loginPwd=`$plistBuddy -c 'Print :LoginPwd' $configPlist`
	devCodeSignIdentityForPersion=`$plistBuddy -c 'Print :Individual:devCodeSignIdentity' $configPlist`
	disCodeSignIdentityForPersion=`$plistBuddy -c 'Print :Individual:disCodeSignIdentity' $configPlist`
	devCodeSignIdentityForEnterprise=`$plistBuddy -c 'Print :Enterprise:devCodeSignIdentity' $configPlist`
	disCodeSignIdentityForEnterprise=`$plistBuddy -c 'Print :Enterprise:disCodeSignIdentity' $configPlist`
	bundleIdsForPersion=`$plistBuddy -c 'Print :Individual:bundleIdentifiers' $configPlist`
	bundleIdsForEnterprise=`$plistBuddy -c 'Print :Enterprise:bundleIdentifiers' $configPlist`
}
function clean
{
	for file in `ls $backupDir` ; do
		logit "清除上一次打包的文件或者文件夹：$file"
		if [[ "$file" != 'History' ]]; then
			if [[ ! -f "$backupDir/$file" ]]; then
				continue;
			fi
			mv -f $backupDir/$file $backupHistoryDir
			if [[ $? -ne 0 ]]; then
				errorExit "备份历史文件失败!"
			fi
		fi
	done
}

##登录keychain授权
function loginKeychainAccess
{

	#允许访问证书
	$security unlock-keychain -p $loginPwd "$HOME/Library/Keychains/login.keychain" 2>/tmp/log.txt
	if [[ $? -ne 0 ]]; then
		errorExit "security unlock-keychain 失败!请检查脚本配置密码是否正确"

	fi
	$security unlock-keychain -p $loginPwd "$HOME/Library/Keychains/login.keychain-db" 2>/tmp/log.txt
		if [[ $? -ne 0 ]]; then
		errorExit "security unlock-keychain 失败!请检查脚本配置密码是否正确"

	fi
}

##xcode 8.3之后使用-exportFormat导出IPA会报错 xcodebuild: error: invalid option '-exportFormat',改成使用-exportOptionsPlist
function generateOptionsPlist
{
	teamId=$1
	method=$2
	plistfileContent="
	<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n
	<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n
	<plist version=\"1.0\">\n
	<dict>\n
	<key>teamID</key>\n
	<string>$teamId</string>\n
	<key>method</key>\n
	<string>$method</string>\n
	<key>compileBitcode</key>\n
	<false/>\n
	</dict>\n
	</plist>\n
	"
	echo -e $plistfileContent > /tmp/optionsplist.plist
}


###检查输入的分发渠道
function checkChannel
{
	OPTARG=$1
	if [[ "$OPTARG" != "development" ]] && [[ "$OPTARG" != "app-store" ]] && [[ "$OPTARG" != "enterprise" ]]; then
		echo "-c 参数不能配置值：$OPTARG"
		usage
		exit 1
	fi
	channel=${OPTARG}

}



##设置命令快捷方式
# function setAliasShortCut
# {
# 	bashProfile=$HOME/.bash_profile
# 	if [[ ! -f $bashProfile ]]; then
# 		touch $bashProfile
# 	fi
# 	shellFilePath="$currentShellDir/`basename "$0"`"
#
# 	aliasString="alias gn=\"$shellFilePath -g\""
# 	grep "$aliasString" $bashProfile
# 	if [[ $? -ne 0 ]]; then
# 		echo $aliasString >> $bashProfile
# 	fi
# }

function usage
{
	# setAliasShortCut
	echo ""
	echo "  -p <Xcode Project File>: 指定Xcode project. 否则，脚本会在当前执行目录中查找Xcode Project 文件"
	echo "  -g: 获取当前项目git的版本数量"
	echo "  -l: 列举可用的codeSign identity."
	echo "  -x: 脚本执行调试模式."
	echo "  -d: 设置debug模式，默认release模式."
	echo "  -t: 设置为测试(开发)环境，默认为生产环境."
	echo "	-r <体系结构>,例如：-r 'armv7'或者 -r 'arm64' 或者 -r 'armv7 arm64' 等"
	echo "  -c <development|app-store|enterprise>: development 内部分发，app-store商店分发，enterprise企业分发"
	echo "  -h: 帮助."
}

##显示可用的签名
function showUsableCodeSign
{
	#先输出签名，再将输出的结果空格' '替换成'#',并赋值给数组。（因为数组的分隔符是空格' '）
	signList=(`$security find-identity -p codesigning -v | awk -F '"' '{print $2}' | tr -s '\n' | tr -s ' ' '#'`)
	for (( i = 0; i < ${#signList[@]}; i++ )); do
		usableCodeSign=`echo ${signList[$i]} | tr '#' ' '`
		usableCodeSignList[$i]=$usableCodeSign
	done
	#打印签名
	for (( i = 0; i < ${#usableCodeSignList[@]}; i++ )); do
		echo "${usableCodeSignList[$i]}"
	done
}


##检查xcode project
function checkForProjectFile
{

	##如果没有指定xcode项目，那么自行在当前目录寻找
	if [[ "$xcodeProject" == '' ]]; then
		pwd=`pwd`
		xcodeProject=`find "$pwd" -maxdepth 1  -type d -name "*.xcodeproj"`
	fi

	projectExtension=`basename "$xcodeProject" | cut -d'.' -f2`
	if [[ "$projectExtension" != "xcodeproj" ]]; then
		errorExit "Xcode project 应该带有.xcodeproj文件扩展，.${projectExtension}不是一个Xcode project扩展！"
	else
		projectFile="$xcodeProject/project.pbxproj"
		if [[ ! -f "$projectFile" ]]; then
			errorExit "项目文件:\"$projectFile\" 不存在"
		fi
		logit "发现pbxproj:\"$projectFile\""
	fi


}

##检查是否存在workplace,当前只能通过遍历的方法来查找
function checkIsExistWorkplace
{
	xcworkspace=`find "$xcodeProject/.." -maxdepth 1  -type d -name "*.xcworkspace"`
	if [[ -d "$xcworkspace" ]]; then
		isExistXcWorkspace=true
		logit "发现xcworkspace:$xcworkspace"
	else
		isExistXcWorkspace=false;
	fi
}


##检查配置文件
function checkEnvironmentConfigureFile
{
	environmentConfigureFile=`find "$xcodeProject/.." -maxdepth 5 -path "./.Trash" -prune -o -type f -name "$environmentConfigFileName" -print| head -n 1`
	if [[ ! -f "$environmentConfigureFile" ]]; then
		haveConfigureEnvironment=false;
		logit "接口环境配置文件${environmentConfigFileName}不存在,忽略接口生产/开发环境配置"
	else
		haveConfigureEnvironment=true;
		logit "发现接口环境配置文件:${environmentConfigureFile}"
	fi
}

function getEnvirionment
{
	if [[ $haveConfigureEnvironment == true ]]; then
		environmentValue=$(grep "$environmentConfigVariableName" "$environmentConfigureFile" | grep -v '^//' | cut -d ";" -f 1 | cut -d "=" -f 2 | sed 's/^[ \t]*//g' | sed 's/[ \t]*$//g')
		currentEnvironmentValue=$environmentValue
		logit "当前接口配置环境kBMIsTestEnvironment:$currentEnvironmentValue"
	fi


}


##获取git版本数量
function getGitVersionCount
{
	gitVersionCount=`git -C "$xcodeProject" rev-list HEAD | wc -l | grep -o "[^ ]\+\( \+[^ ]\+\)*"`
	logit "当前版本数量:$gitVersionCount"
}

##根据授权文件，自动匹配授权文件和签名身份



##获取授权文件过期天数
function getProvisionfileExpirationDays
{
    mobileProvisionFile=$1

    ##切换到英文环境，不然无法转换成时间戳
    export LANG="en_US.UTF-8"
    ##获取授权文件的过期时间
    profileExpirationDate=`$plistBuddy -c 'Print :ExpirationDate' /dev/stdin <<< $($security cms -D -i "$mobileProvisionFile" 2>/tmp/log.txt)`
    profileExpirationTimestamp=`date -j -f "%a %b %d  %T %Z %Y" "$profileExpirationDate" "+%s"`
    nowTimestamp=`date +%s`
    r=$[profileExpirationTimestamp-nowTimestamp]
    expirationDays=$[r/60/60/24]
}

function autoMatchProvisionFile
{
	##授权文件默认放置在和脚本同一个目录下的MobileProvisionFile 文件夹中
	mobileProvisionFileDir="$( cd "$( dirname "$0"  )" && pwd  )/MobileProvisionFile"
	if [[ ! -d "$mobileProvisionFileDir" ]]; then
		errorExit "授权文件目录${mobileProvisionFileDir}不存在！"
	fi

	matchMobileProvisionFile=''
	for file in ${mobileProvisionFileDir}/*.mobileprovision; do
		applicationIdentifier=`$plistBuddy -c 'Print :Entitlements:application-identifier' /dev/stdin <<< $($security cms -D -i "$file" 2>/tmp/log.txt )`
		applicationIdentifier=${applicationIdentifier#*.}
		if [[ "$appBundleId" == "$applicationIdentifier" ]]; then
			getProfileType $file
			if [[ "$profileType" == "$channel" ]]; then
				matchMobileProvisionFile=$file
				logit "授权文件匹配成功：${applicationIdentifier}，路径：$file"
                profileTypeToName "${channel}"
                logit "授权文件分发渠道：$profileTypeName"
				break
			fi
		fi
	done

	if [[ $matchMobileProvisionFile == '' ]]; then
        profileTypeToName "${channel}"
		errorExit "无法匹配${applicationIdentifier} 分发渠道为【${profileTypeName}】的授权文件"
	fi

    ##企业分发，那么检查授权文件有效期
    if [[ "$channel" == 'enterprise' ]];then
        getProvisionfileExpirationDays "$matchMobileProvisionFile"
        logit "授权文件有效时长：${expirationDays} 天";
        if [[ $expirationDays -lt 0 ]];then
            profileExpirationDate=`$plistBuddy -c 'Print :ExpirationDate' /dev/stdin <<< $($security cms -D -i "$matchMobileProvisionFile" 2>/tmp/log.txt)`
            errorExit "授权文件已经过期, 请联系开发人员更换授权文件! 有效日期:${profileExpirationDate}, 过期天数：${expirationDays#-} 天"
        elif [[ $expirationDays -le 90 ]];then
            errorExit "授权文件即将过期, 请联系开发人员更换授权文件! 有效日期:${profileExpirationDate} ,剩余天数：${expirationDays} 天"
        fi
    fi


	##获取授权文件uuid、name、teamId
	profileUuid=`$plistBuddy -c 'Print :UUID' /dev/stdin <<< $($security cms -D -i "$matchMobileProvisionFile" 2>/tmp/log.txt)`
	profileName=`$plistBuddy -c 'Print :Name' /dev/stdin <<< $($security cms -D -i "$matchMobileProvisionFile" 2>/tmp/log.txt)`
	profileTeamId=`$plistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' /dev/stdin <<< $($security cms -D -i "$matchMobileProvisionFile" 2>/tmp/log.txt)`
	if [[ "$profileUuid" == '' ]]; then
		errorExit "profileUuid=$profileUuid, 获取参数配置Profile的uuid失败!"
	fi
	if [[ "$profileName" == '' ]]; then
		errorExit "profileName=$profileName, 获取参数配置Profile的name失败!"
	fi
	logit "发现授权文件参数配置:${profileName}, uuid：$profileUuid, teamId:$profileTeamId"

}

function autoMatchCodeSignIdentity
{

	matchCodeSignIdentity=''
	if [[ "${bundleIdsForPersion[@]}" =~ "$appBundleId" ]]; then
		if [[ "$channel" == 'development' ]]; then
			matchCodeSignIdentity=$devCodeSignIdentityForPersion
		elif [[ "$channel" == 'app-store' ]]; then
			matchCodeSignIdentity=$disCodeSignIdentityForPersion
		fi
	elif [[ "${bundleIdsForEnterprise[@]}" =~ "$appBundleId" ]]; then
		if [[ "$channel" == 'development' ]]; then
			matchCodeSignIdentity=$devCodeSignIdentityForEnterprise
		elif [[ "$channel" == 'enterprise' ]]; then
			matchCodeSignIdentity=$disCodeSignIdentityForEnterprise
		fi
	else
		errorExit "无法匹配【${appBundleId}】的应用的签名，请检查Bundle Id “${$appBundleId}”是否配置在脚本开头的配置列表中!"
	fi
	logit "匹配到${applicationIdentifier}的签名:$matchCodeSignIdentity"
}

##这里只取第一个target
function getFirstTargets
{
	rootObject=`$plistBuddy -c "Print :rootObject" "$projectFile"`
	targetList=`$plistBuddy -c "Print :objects:${rootObject}:targets" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
	targets=(`echo $targetList`);#括号用于初始化数组,例如arr=(1,2,3)
	##这里，只取第一个target,因为默认情况下xcode project 会有自动生成Tests 以及 UITests 两个target
	targetId=${targets[0]}
	targetName=`$plistBuddy -c "Print :objects:$targetId:name" "$projectFile"`
	logit "target名字：$targetName"
	# buildTargetNames=(${buildTargetNames[*]} $targetName)



}


function getAPPBundleId
{
	targetId=${targets[0]}
	buildConfigurationListId=`$plistBuddy -c "Print :objects:$targetId:buildConfigurationList" "$projectFile"`
	buildConfigurationList=`$plistBuddy -c "Print :objects:$buildConfigurationListId:buildConfigurations" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
	buildConfigurations=(`echo $buildConfigurationList`)
	##因为无论release 和 debug 配置中bundleId都是一致的，所以随便取一个即可
	configurationId=${buildConfigurations[0]}
	appBundleId=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:PRODUCT_BUNDLE_IDENTIFIER" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
	if [[ "$appBundleId" == '' ]]; then
		errorExit "获取APP Bundle Id 是失败!!!"
	fi
	logit "appBundleId:$appBundleId"

}



##获取BuildSetting 配置
function showBuildSetting
{
	logitVerbose "======================查看当前Build Setting 配置======================"

	targetId=${targets[0]}

	buildConfigurationListId=`$plistBuddy -c "Print :objects:$targetId:buildConfigurationList" "$projectFile"`
	logitVerbose "配置targetId：$buildConfigurationListId"
	buildConfigurationList=`$plistBuddy -c "Print :objects:$buildConfigurationListId:buildConfigurations" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
	buildConfigurations=(`echo $buildConfigurationList`)
	for configurationId in ${buildConfigurations[@]}; do

		configurationName=`$plistBuddy -c "Print :objects:$configurationId:name" "$projectFile"`
		logitVerbose "Target构建模式(Debug/release): $configurationName"
		# CODE_SIGN_ENTITLEMENTS 和 CODE_SIGN_RESOURCE_RULES_PATH 不一定存在，这里不做判断
		# codeSignEntitlements=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:CODE_SIGN_ENTITLEMENTS" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		# codeSignResourceRulePath=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:CODE_SIGN_RESOURCE_RULES_PATH" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		codeSignIdentity=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:CODE_SIGN_IDENTITY" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		codeSignIdentitySDK=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:CODE_SIGN_IDENTITY[sdk=iphoneos*]" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		developmentTeam=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:DEVELOPMENT_TEAM" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		infoPlistFile=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:INFOPLIST_FILE" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		iphoneosDeploymentTarget=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:IPHONEOS_DEPLOYMENT_TARGET" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		onlyActiveArch=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:ONLY_ACTIVE_ARCH" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		productBundleIdentifier=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:PRODUCT_BUNDLE_IDENTIFIER" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		productName=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:PRODUCT_NAME" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		provisionProfileUuid=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:PROVISIONING_PROFILE" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		provisionProfileName=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:PROVISIONING_PROFILE_SPECIFIER" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`

		# logit "codeSignEntitlements:$codeSignEntitlements"
		# logit "codeSignResourceRulePath:$codeSignResourceRulePath"

		logitVerbose "developmentTeam:$developmentTeam"
		logitVerbose "infoPlistFile:$infoPlistFile"
		logitVerbose "iphoneosDeploymentTarget:$iphoneosDeploymentTarget"
		logitVerbose "onlyActiveArch:$onlyActiveArch"
		logitVerbose "BundleId:$productBundleIdentifier"
		logitVerbose "productName:$productName"
		logitVerbose "provisionProfileUuid:$provisionProfileUuid"
		logitVerbose "provisionProfileName:$provisionProfileName"
		logitVerbose "codeSignIdentity:$codeSignIdentity"
		logitVerbose "codeSignIdentitySDK:$codeSignIdentitySDK"
	done
}






##检查授权文件类型
function getProfileType
{
	profile=$1
	# provisionedDevices=`$plistBuddy -c 'Print :ProvisionedDevices' /dev/stdin <<< $($security cms -D -i "$profile"  ) | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
	##判断是否存在key:ProvisionedDevices
	haveKey=`$security cms -D -i "$profile" 2>/tmp/log.txt | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//' | grep ProvisionedDevices`
	if [[ $? -eq 0 ]]; then
		getTaskAllow=`$plistBuddy -c 'Print :Entitlements:get-task-allow' /dev/stdin <<< $($security cms -D -i "$profile" 2>/tmp/log.txt) `
		if [[ $getTaskAllow == true ]]; then
			profileType='development'
		else
			profileType='ad-hoc'
		fi
	else

		haveKeyProvisionsAllDevices=`$security cms -D -i "$profile" 2>/tmp/log.txt  | grep ProvisionsAllDevices`
		if [[ "$haveKeyProvisionsAllDevices" != '' ]]; then
			provisionsAllDevices=`$plistBuddy -c 'Print :ProvisionsAllDevices' /dev/stdin <<< $($security cms -D -i "$profile" 2>/tmp/log.txt) `
			if [[ $provisionsAllDevices == true ]]; then
				profileType='enterprise'
			else
				profileType='app-store'
			fi
		else
			profileType='app-store'
		fi
	fi
}

##设置build version
function setBuildVersion
{

	for targetId in ${targets[@]}; do
		buildConfigurationListId=`$plistBuddy -c "Print :objects:$targetId:buildConfigurationList" "$projectFile"`
		buildConfigurationList=`$plistBuddy -c "Print :objects:$buildConfigurationListId:buildConfigurations" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		buildConfigurations=(`echo $buildConfigurationList`)
		for configurationId in ${buildConfigurations[@]}; do
			infoPlistFile=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:INFOPLIST_FILE" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		done
	done

	infoPlistFilePath="$xcodeProject"/../$infoPlistFile
	if [[ -f "$infoPlistFilePath" ]]; then
		$plistBuddy -c "Set :CFBundleVersion $gitVersionCount" "$infoPlistFilePath"
		logit "设置Buil Version:${gitVersionCount}"
	else
		errorExit "${infoPlistFilePath}文件不存在，无法修改"
	fi


}

##配置证书身份和授权文件
function configureSigningByRuby
{
	logit "========================配置签名身份和描述文件========================"
	rbDir="$( cd "$( dirname "$0"  )" && pwd  )"
	ruby ${rbDir}/xcocdeModify.rb "$xcodeProject" $profileUuid $profileName "$matchCodeSignIdentity"  $profileTeamId
	if [[ $? -ne 0 ]]; then
		errorExit "xcocdeModify.rb 修改配置失败！！"
	fi
	logit "========================配置完成========================"
}


##设置生产环境或者
function setEnvironment
{
	if [[ $haveConfigureEnvironment == true ]]; then
		bakExtension=".bak"
		bakFile=${environmentConfigureFile}${bakExtension}
		if [[ $productionEnvironment == true ]]; then
			if [[ "$currentEnvironmentValue" != "NO" ]]; then
				sed -i "$bakExtension" "/kBMIsTestEnvironment/s/YES/NO/" "$environmentConfigureFile" && rm -rf $bakFile
				logit "设置配置环境kBMIsTestEnvironment:NO"
			fi
		else
			if [[ "$currentEnvironmentValue" != "YES" ]]; then
				sed -i "$bakExtension" "/kBMIsTestEnvironment/s/NO/YES/" "$environmentConfigureFile" && rm -rf $bakFile
				logit "设置配置环境kBMIsTestEnvironment:YES"
			fi
		fi
	fi
}

##设置NO,只打标准arch
function setOnlyActiveArch
{
	for configurationId in ${buildConfigurations[@]}; do
		configurationName=`$plistBuddy -c "Print :objects:$configurationId:name" "$projectFile"`
		onlyActiveArch=`$plistBuddy -c "Print :objects:$configurationId:buildSettings:ONLY_ACTIVE_ARCH" "$projectFile" | sed -e '/Array {/d' -e '/}/d' -e 's/^[ \t]*//'`
		if [[ "$onlyActiveArch" != "NO" ]]; then
			$plistBuddy -c "Set :objects:$configurationId:buildSettings:ONLY_ACTIVE_ARCH NO" "$projectFile"
			logit "设置${configurationName}模式的ONLY_ACTIVE_ARCH:NO"
		fi

	done
}


##设置手动签名,即不勾选：Xcode -> General -> Signing -> Automatically manage signning

##获取签名方式
function getCodeSigningStyle
{
	##没有勾选过Automatically manage signning时，则不存在ProvisioningStyle
	signingStyle=`$plistBuddy -c "Print :objects:$rootObject:attributes:TargetAttributes:$targetId:ProvisioningStyle " "$projectFile"`
	logit "获取到target:${targetName}签名方式:$signingStyle"
}

function setManulSigning
{
	if [[ "$signingStyle" != "Manual" ]]; then
		##如果需要设置成自动签名,将Manual改成Automatic
		$plistBuddy -c "Set :objects:$rootObject:attributes:TargetAttributes:$targetId:ProvisioningStyle Manual" "$projectFile"
		logit "设置${targetName}的签名方式为:Manual"
	fi
}


###开始构建
function build
{
	packageDir="$xcodeProject"/../build/package
	rm -rf "$packageDir"/*
	if [[ $debugConfiguration == true ]]; then
		configuration="Debug"
	else
		configuration="Release"
	fi

	archivePath="${packageDir}"/$targetName.xcarchive
	exprotPath="${packageDir}"/$targetName.ipa


	if [[ -d "$archivePath" ]]; then
		rm -rf "$archivePath"
	fi

	if [[ -f "$exprotPath" ]]; then
		rm -rf "$exprotPath"
	fi


	if [[ $isExistXcWorkspace == true ]]; then

		##如果使用development，那么都指定archs=armv7 （向下兼容）
		if [[ "$profileType" == "development" ]]; then
			$xcodebuild archive -workspace "$xcworkspace" -scheme "$targetName" -archivePath "$archivePath" -configuration $configuration clean build ARCHS="$arch"
		else
			$xcodebuild archive -workspace "$xcworkspace" -scheme "$targetName" -archivePath "$archivePath" -configuration $configuration clean build
		fi

	else
		##如果使用development，那么都指定archs=armv7 （向下兼容）
		if [[ "$profileType" == "development" ]]; then
			$xcodebuild archive	-scheme "$targetName" -archivePath "$archivePath" -configuration $configuration clean build ARCHS="$arch"
		else
			$xcodebuild archive	-scheme "$targetName" -archivePath "$archivePath" -configuration $configuration clean build
		fi



	fi

	if [[ $? -ne 0 ]]; then

		rm -rf "${packageDir}"/*
        errorExit "xcodebuild build 构建失败!"
	fi

	##获取当前xcodebuild版本
	xcVersion=`$xcodebuild -version | head -1 | cut -d " " -f 2`
	logit "xcodebuild 当前版本:$xcVersion"
	if versiongreatethen "$xcVersion" "8.3"; then
		generateOptionsPlist "$profileTeamId" "$profileType"
		##发现在xcode8.3 之后-exportPath 参数需要指定一个目录，而8.3之前参数指定是一个带文件名的路径！坑！
		$xcodebuild -exportArchive -archivePath "$archivePath" -exportPath "$packageDir" -exportOptionsPlist /tmp/optionsplist.plist

	else
		$xcodebuild -exportArchive -exportFormat IPA -archivePath "$archivePath" -exportPath "$exprotPath"
	fi

	if [[ $? -eq 0 ]]; then
		logit "打包成功,IPA生成路径：\"$exprotPath\""
	else
		errorExit "$xcodebuild exportArchive  执行失败!"
	fi

}

##在打企业包的时候：会报 archived-expanded-entitlements.xcent  文件缺失!这是xcode的bug
##链接：http://stackoverflow.com/questions/28589653/mac-os-x-build-server-missing-archived-expanded-entitlements-xcent-file-in-ipa
function repairXcentFile
{

	appName=`basename "$exprotPath" .ipa`
	xcentFile="${archivePath}"/Products/Applications/"${appName}".app/archived-expanded-entitlements.xcent
	if [[ -f "$xcentFile" ]]; then
		logit  "拷贝xcent文件：\"$xcentFile\" "
		unzip -o "$exprotPath" -d /"$packageDir" >/dev/null 2>&1
		app="${packageDir}"/Payload/"${appName}".app
		cp -af "$xcentFile" "$app"
		##压缩,并覆盖原有的ipa
		cd "${packageDir}"  ##必须cd到此目录 ，否则zip会包含绝对路径
		zip -qry  "$exprotPath" Payload >/dev/null 2>&1 && rm -rf Payload
		cd -
	else
		errorExit "\"$xcentFile\" 文件不存在，修复Xcent文件失败!"
	fi

}

##构建完成，检查App
function checkIPA
{

	##解压强制覆盖，并不输出日志

	if [[ -d /tmp/Payload ]]; then
		rm -rf /tmp/Payload
	fi
	unzip -o "$exprotPath" -d /tmp/ >/dev/null 2>&1
	appName=`basename "$exprotPath" .ipa`
	app=/tmp/Payload/"${appName}".app
	codesign --no-strict -v "$app"
	if [[ $? -ne 0 ]]; then
		errorExit "签名检查：签名校验不通过！"
	fi
	logit ""
	logit "==============签名检查：签名校验通过！==============="
	if [[ -d "$app" ]]; then
		infoPlistFile=${app}/Info.plist
		mobileProvisionFile=${app}/embedded.mobileprovision

		appShowingName=`$plistBuddy -c "Print :CFBundleName" $infoPlistFile`
		appBundleId=`$plistBuddy -c "print :CFBundleIdentifier" "$infoPlistFile"`
		appVersion=`$plistBuddy -c "Print :CFBundleShortVersionString" $infoPlistFile`
		appBuildVersion=`$plistBuddy -c "Print :CFBundleVersion" $infoPlistFile`
		appMobileProvisionName=`$plistBuddy -c 'Print :Name' /dev/stdin <<< $($security cms -D -i "$mobileProvisionFile" 2>/tmp/log.txt)`
		appMobileProvisionCreationDate=`$plistBuddy -c 'Print :CreationDate' /dev/stdin <<< $($security cms -D -i "$mobileProvisionFile" 2>/tmp/log.txt)`
        #授权文件有效时间
		appMobileProvisionExpirationDate=`$plistBuddy -c 'Print :ExpirationDate' /dev/stdin <<< $($security cms -D -i "$mobileProvisionFile" 2>/tmp/log.txt)`
        getProvisionfileExpirationDays "$mobileProvisionFile"
		appCodeSignIdenfifier=`$codesign --display -r- "$app" | cut -d "\"" -f 4`
		#支持最小的iOS版本
		supportMinimumOSVersion=`$plistBuddy -c "print :MinimumOSVersion" "$infoPlistFile"`
		#支持的arch
		supportArchitectures=`$lipo -info "$app"/"$appName" | cut -d ":" -f 3`

		logit "名字:$appShowingName"
		getEnvirionment
		logit "配置环境kBMIsTestEnvironment:$currentEnvironmentValue"
		logit "bundle identify:$appBundleId"
		logit "版本:$appVersion"
		logit "build:$appBuildVersion"
		logit "支持最低iOS版本:$supportMinimumOSVersion"
		logit "支持的arch:$supportArchitectures"
		logit "签名:$appCodeSignIdenfifier"
		logit "授权文件:${appMobileProvisionName}.mobileprovision"
		logit "授权文件创建时间:$appMobileProvisionCreationDate"
		logit "授权文件过期时间:$appMobileProvisionExpirationDate"
        logit "授权文件有效天数：${expirationDays} 天"
		getProfileType "$mobileProvisionFile"
        profileTypeToName "$profileType"
		logit "分发渠道:$profileTypeName"

	else
		errorExit "解压失败！无法找到$app"
	fi
}



##重命名和备份
function renameAndBackup
{

	if [[ ! -d backupHistoryDir ]]; then
		mkdir -p $backupHistoryDir
	fi

	if [[ $haveConfigureEnvironment == true ]]; then
		if [[ "$currentEnvironmentValue" == 'YES' ]]; then
			environmentName='开发环境'
		else
			environmentName='生产环境'
		fi
	else
		environmentName='未知环境'
	fi

    profileTypeToName "$profileType"

	date=`date +"%Y%m%d_%H%M%S"`
	name=${appShowingName}_${date}_${environmentName}_${profileTypeName}_${appVersion}\($appBuildVersion\)
	ipaName=${name}.ipa
	textLogName=${name}.txt
	logit "ipa重命名并备份到：$backupDir/$ipaName"

	mv "$exprotPath" "$packageDir"/$ipaName
	cp -af "$packageDir"/$ipaName $backupDir/$ipaName
	cp -af $tmpLogFile $backupDir/$textLogName

}


startDateSeconds=`date +%s`


while getopts p:c:r:xvhgtl option; do
  case "${option}" in
  	g) getGitVersionCount;exit;;
    p) xcodeProject=${OPTARG};;
		c) checkChannel ${OPTARG};;
		t) productionEnvironment=false;;
		l) showUsableCodeSign;exit;;
		r) arch=${OPTARG};;
    x) set -x;;
		d) debugConfiguration=true;;
    v) verbose=true;;
    h | help) usage; exit;;
	* ) usage;exit;;
  esac
done



clean
initConfiguration
loginKeychainAccess
checkForProjectFile
checkIsExistWorkplace
checkEnvironmentConfigureFile

getEnvirionment
getFirstTargets
getAPPBundleId
autoMatchProvisionFile
autoMatchCodeSignIdentity
getGitVersionCount
getCodeSigningStyle
setEnvironment
setBuildVersion
configureSigningByRuby
showBuildSetting

build
repairXcentFile
checkIPA
renameAndBackup

endDateSeconds=`date +%s`

logit "构建时长：$((${endDateSeconds}-${startDateSeconds})) 秒"


#所有的Set方法，目前都被屏蔽掉。因为当使用PlistBuddy修改工程配置时，会导致工程对中文解析出错！！！
