#!/bin/bash

# bash <(curl -s -o- https://raw.githubusercontent.com/aws-samples/siem-on-amazon-elasticsearch/develop/deployment/auto_setup_on_cloudshell.sh)
# or add git commit id at the end of line
# bash <(curl -s -o- https://raw.githubusercontent.com/aws-samples/siem-on-amazon-elasticsearch/develop/deployment/auto_setup_on_cloudshell.sh) develop

###############################################################################
# helper Function
###############################################################################
LOG_OUT="$HOME/auto_setup_on_cloudshell-$(date "+%Y%m%d_%H%M%S").log"
exec 2> >(tee -a "${LOG_OUT}") 1>&2

export BASEDIR="$HOME/siem-on-amazon-elasticsearch-service"
export OLDDIR="$HOME/siem-on-amazon-elasticsearch"

function func_check_freespace() {
  if [ -d "$BASEDIR" ];then
    find "$BASEDIR" -name "*.zip" | xargs rm -f
    rm -fr "${BASEDIR}/source/cdk/cdk.out"
  fi
  if [ -d "$OLDDIR" ];then
    find "$OLDDIR" -name "*.zip" | xargs rm -f
    rm -fr "${OLDDIR}/source/cdk/.env"
    rm -fr "${OLDDIR}/source/cdk/cdk.out"
  fi
  free_space=$(df -m "$HOME" | awk '/[0-9]%/{print $(NF-2)}')
  echo "Free space is ${free_space} MB"
  if [ "${free_space}" -le 250 ] && [ -d ~/.nvm/versions/node/ ]; then
    ls -d ~/.nvm/versions/node/* | grep -v $(ls -t ~/.nvm/versions/node/ | head -1) | xargs rm -rf
  fi
  if [ "${free_space}" -le 250 ]; then
    echo "At least 250 MB of free space needed."
    echo "Exit."
    echo "Delete unnecessary files, or Delete AWS CloudShell home directory."
    exit
  fi
  echo ""
}

function func_migrate_old_repo_to_new_repo () {
  if [ -s "${OLDDIR}/source/cdk/cdk.json" ]; then
    if [ ! -e "${BASEDIR}/source/cdk/cdk.json" ]; then
      cp "${OLDDIR}/source/cdk/cdk.json" "${BASEDIR}/source/cdk/cdk.json"
    fi
  fi
  if [ -s "${OLDDIR}/source/cdk/cdk.context.json" ]; then
    if [ ! -e "${BASEDIR}/source/cdk/cdk.context.json" ]; then
      cp "${OLDDIR}/source/cdk/cdk.context.json" "${BASEDIR}/source/cdk/cdk.context.json"
    fi
  fi
}

function func_put_to_ssm_param () {
  cd $BASEDIR/source/cdk
  put_obj=$1
  aws ssm put-parameter \
    --name "/aes-siem/cdk/$put_obj" \
    --overwrite \
    --region "$AWS_DEFAULT_REGION" \
    --value "$(cat ${put_obj})" \
    --type String
  echo "PUT $put_obj to SSM Parameter store"
}

function func_get_from_param_store () {
  cd $BASEDIR/source/cdk
  get_obj=$1
  aws ssm get-parameter \
    --name "/aes-siem/cdk/$get_obj" \
    --region "$AWS_DEFAULT_REGION" \
    --query "Parameter.Value" \
    --output text > "${get_obj}.ssm" 2> /dev/null
  if [ -s "${get_obj}.ssm" ]; then
    echo "GET $get_obj from SSM Parameter store"
  else
    rm "${get_obj}.ssm"
  fi
}

function func_update_param () {
  cd $BASEDIR/source/cdk
  file_obj=$1
  func_get_from_param_store "${file_obj}"
  if [ ! -s "$file_obj.ssm" ]; then
    # not file in ssm
    if [ -s "$file_obj" ]; then
      func_put_to_ssm_param "${file_obj}"
    fi
  else
    if [ -s "$file_obj" ]; then
      is_changed=`diff $file_obj $file_obj.ssm| wc -l`
      if [ $is_changed != "0" ]; then
        func_put_to_ssm_param $file_obj
      fi
    fi
    rm $file_obj.ssm
  fi
}

function func_check_or_get_exiting_cdk_json () {
  suffix=`date "+%Y%m%d_%H%M%S"`
  func_get_from_param_store cdk.json
  if [ -s "cdk.json" ]; then
    if [ -s "cdk.json.ssm" ]; then
      file_diff=`diff cdk.json.ssm cdk.json | wc -l`
      if [ "$file_diff" != "0" ]; then
        # different file
        echo "cdk.json on local and downloaded cdk.json from SSM parameter store are different."
        echo ""
        diff cdk.json cdk.json.ssm
        echo ""
        echo "Above lines are different"
        echo "  < exist only local cdk.json"
        echo "  > exist only downloaded cdk.json from SSM parameter store"
        mv cdk.json "cdk.json-$suffix"
        mv cdk.json.ssm cdk.json
        echo "cdk.json in local is backupped to cdk.json-$suffix"
        echo ""
      else
        # cdk.json and cdk.json.ssm are same file
        rm cdk.json.ssm
      fi
    else
      # There is no file in ssm paramater stores.
      # This may be first time to execute this script
      func_put_to_ssm_param cdk.json
    fi
  elif [ -f "cdk.json.ssm" ]; then
    # CDK was deployed and cdk.json is stored in ssm, but this is new environment
    mv cdk.json.ssm cdk.json
  fi

  func_get_from_param_store cdk.context.json
  if [ -s "cdk.context.json" ]; then
    if [ -s "cdk.context.json.ssm" ]; then
      file_diff=`diff cdk.context.json.ssm cdk.context.json | wc -l`
      if [ "$file_diff" != "0" ]; then
        mv cdk.context.json "cdk.context.json-$suffix"
        mv cdk.context.json.ssm cdk.context.json
      else
        # cdk.json and cdk.json.ssm are same file
        rm cdk.context.json.ssm
      fi
    else
      func_put_to_ssm_param cdk.context.json
    fi
  elif [ -f "cdk.context.json.ssm" ]; then
    mv cdk.context.json.ssm cdk.context.json
  fi
}

function func_ask_and_set_env {
  cd $BASEDIR/source/cdk
  AES_ENV="vpc"
  while true; do
    read -p "Where do you deploy your system? Enter pulic or vpc: default is [vpc]: " AES_ENV
    case $AES_ENV in
      '' | 'vpc' )
        echo deply Amazon ES in VPC
        export AES_ENV="vpc"
        cp cdk.json.vpc.sample cdk.json
        break;
        ;;
      'public' )
        echo deply Amazon ES on public environment
        export AES_ENV="public"
        cp cdk.json.public.sample cdk.json
        break;
        ;;
      * )
        echo Please enter public or vpn.
    esac
  done;
  aws ssm put-parameter \
    --name "/aes-siem/cdk/cdk.json" \
    --region "$AWS_DEFAULT_REGION" \
    --value "$(cat cdk.json)" \
    --type String
}

function func_validate_json () {
  echo "func_validate_json"
  cd $BASEDIR/source/cdk
  file_obj=$1
  while true; do
    echo ""
    read -p 'Have you modified cdk.json? [Y(=continue) / n(=exit)]: ' ANSWER
    case $ANSWER in
      [Nn]* )
        echo exit. bye;
        exit;
        ;;
      [Yy]* )
        func_get_from_param_store cdk.json
        cp -f cdk.json.ssm cdk.json
        ERROR_MSG="$(cat ${file_obj} | jq empty 2>&1 > /dev/null)"
        RESULT="$?"
        case $RESULT in
          0 )
            break;
            ;;
          * )
            echo "";
            echo "Woops. Your cdk.json is currupt json format";
            echo "$ERROR_MSG";
            ;;
        esac
        ;;
    esac
  done;
}

function func_continue_or_exit () {
  while true; do
    read -p 'Do you continue or exit? [Y(=continue) / n(=exit)]: ' Answer
    case $Answer in
      [Yy]* )
        echo Continue
        break;
        ;;
      [Nn]* )
        echo exit. bye
        exit;
        ;;
      * )
        echo Please answer YES or NO.
    esac
  done;
}

function func_delete_unnecessary_files() {
  cd "$HOME"
  if [ -d "$BASEDIR" ];then
    find "$BASEDIR" -name "*.zip" | xargs rm -f
    rm -fr "${BASEDIR}/source/cdk/cdk.out"
  fi
  if [ -d "$OLDDIR" ];then
    if [[ $AWS_EXECUTION_ENV == "CloudShell" ]]; then
      tar -zcf "${OLDDIR}.tgz" -C "$HOME/" $(echo $OLDDIR | sed -e "s@$HOME/@@") && rm -fr "$OLDDIR"
    fi
  fi
}

###############################################################################
# main script
###############################################################################
echo "Auto Installtion Script Started"
date

if [ ! $1 ]; then
  commitid='main'
else
  commitid=$1
fi

cd ~/
echo "func_check_freespace"
func_check_freespace

echo "### 1. Setting Up the AWS CDK Execution Environment ###"
echo 'yum groups mark install -y "Development Tools"'
sudo yum groups mark install -y "Development Tools" > /dev/null
echo -e "Done\n"

echo "sudo yum install -y amazon-linux-extras"
sudo yum install -y amazon-linux-extras > /dev/null
echo -e "Done\n"

echo "sudo amazon-linux-extras enable python3.8"
sudo amazon-linux-extras enable python3.8 > /dev/null
echo -e "Done\n"

echo "yum install -y python38 python38-devel git jq"
sudo yum install -y python38 python38-devel git jq > /dev/null
echo -e "Done\n"

sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 1
if [ ! -f /usr/bin/pip3 ]; then
  sudo update-alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.8 1
fi

#if [ -d "siem-on-amazon-elasticsearch" ]; then
if [ -d "$BASEDIR" ]; then
  echo "git rebase to get latest commit"
  cd $BASEDIR
  git fetch > /dev/null
  git checkout main && git pull --rebase > /dev/null
  git checkout develop && git pull --rebase > /dev/null
  git checkout $commitid
  cd $HOME
else
  echo "git clone siem source code"
  git clone https://github.com/aws-samples/siem-on-amazon-elasticsearch-service.git > /dev/null
  cd $BASEDIR
  git checkout $commitid
  cd $HOME
fi
cd $BASEDIR && echo `git log | head -1` && cd $HOME
echo -e "Done\n"

echo "### 2. Setting Environment Variables ###"
### set AWS Accont ###
GUESS_CDK_DEFAULT_ACCOUNT=`aws sts get-caller-identity --query 'Account' --output text`
read -p "Enter CDK_DEFAULT_ACCOUNT: default is [$GUESS_CDK_DEFAULT_ACCOUNT]: " TEMP_CDK_DEFAULT_ACCOUNT
export CDK_DEFAULT_ACCOUNT=${TEMP_CDK_DEFAULT_ACCOUNT:-$GUESS_CDK_DEFAULT_ACCOUNT}

### set AWS Region ###
if [[ $AWS_EXECUTION_ENV == "CloudShell" ]]; then
  GUESS_AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
  unset AWS_REGION
else
  GUESS_AWS_DEFAULT_REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e s/.$//`
fi
read -p "Enter AWS_DEFAULT_REGION to deploy Amazon ES: default is [$GUESS_AWS_DEFAULT_REGION]: " TEMP_AWS_DEFAULT_REGION
export AWS_DEFAULT_REGION=${TEMP_AWS_DEFAULT_REGION:-$GUESS_AWS_DEFAULT_REGION}
export CDK_DEFAULT_REGION=$AWS_DEFAULT_REGION

### print env ###
echo ""
echo "Your AWS account is $CDK_DEFAULT_ACCOUNT"
echo "AWS region of installation target is $CDK_DEFAULT_REGION"
echo ""

### Check if cdk.json exists. If no, create new one ###
echo "func_migrate_old_repo_to_new_repo"
func_migrate_old_repo_to_new_repo
echo "func_check_or_get_exiting_cdk_json"
func_check_or_get_exiting_cdk_json
echo -e "Done\n"
if [ ! -f "cdk.json" ]; then
  ### create new one ###
  echo "There is no existing cdk.json"
  echo "func_ask_and_set_env"
  func_ask_and_set_env > /dev/null
  echo -e "Done\n"
fi

echo "### 3. Creating an AWS Lambda Deployment Package ###"
cd $BASEDIR/deployment/cdk-solution-helper/
echo "./step1-build-lambda-pkg.sh"
date
chmod +x ./step1-build-lambda-pkg.sh && ./step1-build-lambda-pkg.sh > /dev/null
echo -e "Done\n"

echo "### 4. Setting Up the Environment for AWS Cloud Development Kit (AWS CDK) ###"
echo "./step2-setup-cdk-env.sh"
date
chmod +x ./step2-setup-cdk-env.sh && ./step2-setup-cdk-env.sh> /dev/null
source ~/.bash_profile
nvm use lts/*
echo -e "Done\n"

echo "### 5. Setting Installation Options with the AWS CDK ###"
cd $BASEDIR/source/cdk/
source .env/bin/activate
echo "cdk bootstrap"
cdk bootstrap aws://$CDK_DEFAULT_ACCOUNT/$AWS_DEFAULT_REGION; status=$?
if [ $status -ne 0 ]; then
  echo "invalid configuration. exit"
  exit
fi
echo -e "Done\n"

echo "################################################"
echo "# Next Procedure"
echo "################################################"
echo "1. Go to Systems Manager / Parameter Store in selected region"
echo "   https://console.aws.amazon.com/systems-manager/parameters/aes-siem/cdk/cdk.json/"
echo "2. Check and Edit cdk.json file in Parameter Store"
echo "   If you want to update SIEM without changes, please just return "
echo "   see more details https://github.com/aws-samples/siem-on-amazon-elasticsearch/blob/main/docs/deployment.md"
echo ""
echo ""
echo ""
echo ""

func_validate_json cdk.json
echo ""
cat cdk.json
echo ""
echo "Install SIEM in $CDK_DEFAULT_REGION"
echo ""
echo "Is this right? Do you want to continue? "
func_continue_or_exit

(sleep 120 && func_update_param cdk.context.json > /dev/null 2>&1 & )
echo "cdk deploy"
date
cdk deploy; status=$?
if [ $status -ne 0 ]; then
  echo "invalid configuration. exit"
  exit
fi
date

echo "func_update_param cdk.context.json"
func_update_param cdk.context.json

echo "func_delete_unnecessary_files"
func_delete_unnecessary_files

echo "The script was done"
date
