#!/bin/bash

# Check AWS CLI version is >= 2.24.0
check_aws_cli_version() {
    echo "Checking AWS CLI version..."
    
    # Get AWS CLI version
    AWS_CLI_VERSION=$(aws --version 2>&1 | cut -d ' ' -f1 | cut -d '/' -f2)
    echo "Current AWS CLI version: $AWS_CLI_VERSION"
    
    # Extract major and minor versions
    MAJOR_VERSION=$(echo $AWS_CLI_VERSION | cut -d '.' -f1)
    MINOR_VERSION=$(echo $AWS_CLI_VERSION | cut -d '.' -f2)
    PATCH_VERSION=$(echo $AWS_CLI_VERSION | cut -d '.' -f3)
    
    # Check if version is >= 2.24.0
    if [ "$MAJOR_VERSION" -lt 2 ] || [ "$MAJOR_VERSION" -eq 2 -a "$MINOR_VERSION" -lt 24 ]; then
        echo "Error: Current AWS CLI version ($AWS_CLI_VERSION) is lower than the required minimum version 2.24.0"
        echo "Please update AWS CLI to version 2.24.0 or higher."
        echo "You can update using: pip install --upgrade awscli"
        exit 1
    fi
    
    echo "AWS CLI version check passed, continuing execution..."
}

# Function to get instance specifications based on instance type
get_instance_specs() {
    local INSTANCE_TYPE=$1
    local SPECS=""
    
    # Extract instance family and size
    local INSTANCE_FAMILY=$(echo $INSTANCE_TYPE | cut -d '.' -f1-2)
    local INSTANCE_SIZE=$(echo $INSTANCE_TYPE | cut -d '.' -f3)
    
    # Map instance types to their specifications
    local CPU_COUNT="Unknown"
    local MEMORY_GB="Unknown"
    local GPU_COUNT=0
    local GPU_NAME="None"
    
    case "$INSTANCE_FAMILY" in
        "ml.t3")
            case "$INSTANCE_SIZE" in
                "medium") CPU_COUNT=2; MEMORY_GB=4 ;;
                "large") CPU_COUNT=2; MEMORY_GB=8 ;;
                "xlarge") CPU_COUNT=4; MEMORY_GB=16 ;;
                "2xlarge") CPU_COUNT=8; MEMORY_GB=32 ;;
            esac
            ;;
        "ml.m5")
            case "$INSTANCE_SIZE" in
                "large") CPU_COUNT=2; MEMORY_GB=8 ;;
                "xlarge") CPU_COUNT=4; MEMORY_GB=16 ;;
                "2xlarge") CPU_COUNT=8; MEMORY_GB=32 ;;
                "4xlarge") CPU_COUNT=16; MEMORY_GB=64 ;;
                "12xlarge") CPU_COUNT=48; MEMORY_GB=192 ;;
                "24xlarge") CPU_COUNT=96; MEMORY_GB=384 ;;
            esac
            ;;
        "ml.c5")
            case "$INSTANCE_SIZE" in
                "large") CPU_COUNT=2; MEMORY_GB=4 ;;
                "xlarge") CPU_COUNT=4; MEMORY_GB=8 ;;
                "2xlarge") CPU_COUNT=8; MEMORY_GB=16 ;;
                "4xlarge") CPU_COUNT=16; MEMORY_GB=32 ;;
                "9xlarge") CPU_COUNT=36; MEMORY_GB=72 ;;
                "18xlarge") CPU_COUNT=72; MEMORY_GB=144 ;;
            esac
            ;;
        "ml.p3")
            case "$INSTANCE_SIZE" in
                "2xlarge") CPU_COUNT=8; MEMORY_GB=16; GPU_COUNT=1; GPU_NAME="V100" ;;
                "8xlarge") CPU_COUNT=32; MEMORY_GB=64; GPU_COUNT=4; GPU_NAME="V100" ;;
                "16xlarge") CPU_COUNT=64; MEMORY_GB=128; GPU_COUNT=8; GPU_NAME="V100" ;;
            esac
            ;;
        "ml.g4dn")
            case "$INSTANCE_SIZE" in
                "xlarge") CPU_COUNT=4; MEMORY_GB=16; GPU_COUNT=1; GPU_NAME="T4" ;;
                "2xlarge") CPU_COUNT=8; MEMORY_GB=32; GPU_COUNT=1; GPU_NAME="T4" ;;
                "4xlarge") CPU_COUNT=16; MEMORY_GB=64; GPU_COUNT=1; GPU_NAME="T4" ;;
                "8xlarge") CPU_COUNT=32; MEMORY_GB=128; GPU_COUNT=1; GPU_NAME="T4" ;;
                "12xlarge") CPU_COUNT=48; MEMORY_GB=192; GPU_COUNT=4; GPU_NAME="T4" ;;
                "16xlarge") CPU_COUNT=64; MEMORY_GB=256; GPU_COUNT=1; GPU_NAME="T4" ;;
            esac
            ;;
    esac
    
    SPECS="CPU: $CPU_COUNT vCPUs, Memory: $MEMORY_GB GB"
    if [ "$GPU_COUNT" -gt 0 ]; then
        SPECS="$SPECS, GPU: $GPU_COUNT x $GPU_NAME"
    fi
    
    echo "$SPECS"
}

# Check AWS CLI version before proceeding
check_aws_cli_version

echo "==================================================="
echo "SageMaker Studio JupyterLab Environments Report"
echo "==================================================="
echo "Generated on: $(date)"
echo "==================================================="

# List SageMaker Studio domains
echo "Listing SageMaker Studio domains..."
DOMAIN_INFO=$(aws sagemaker list-domains --query 'Domains[].{DomainId:DomainId, DomainName:DomainName}' --output json)

# Extract domain IDs and names from the JSON output
DOMAIN_IDS=$(echo $DOMAIN_INFO | jq -r '.[].DomainId')
DOMAIN_NAMES=$(echo $DOMAIN_INFO | jq -r '.[].DomainName')

IFS=$'\n' read -rd '' -a DOMAIN_ID_ARRAY <<< "$DOMAIN_IDS"
IFS=$'\n' read -rd '' -a DOMAIN_NAME_ARRAY <<< "$DOMAIN_NAMES"

# Counter for JupyterLab environments
TOTAL_JUPYTERLAB_COUNT=0
RUNNING_JUPYTERLAB_COUNT=0
STOPPED_JUPYTERLAB_COUNT=0

for ((i=0; i<${#DOMAIN_ID_ARRAY[@]}; i++)); do
  DOMAIN_ID="${DOMAIN_ID_ARRAY[$i]}"
  DOMAIN_NAME="${DOMAIN_NAME_ARRAY[$i]}"
  echo "Domain: $DOMAIN_NAME (ID: $DOMAIN_ID)"

  # List spaces in the domain
  echo "Listing spaces in domain..."
  SPACE_NAMES=$(aws sagemaker list-spaces --domain-id $DOMAIN_ID --query 'Spaces[].SpaceName' --output text)

  # Initialize dictionaries to store the counts and instance details for this domain
  declare -A profile_counts
  declare -A profile_instances

  # Check if there are any spaces
  if [ -z "$SPACE_NAMES" ]; then
    echo "  No spaces found in this domain."
    continue
  fi

  for SPACE_NAME in $SPACE_NAMES; do
    echo "  Space Name: $SPACE_NAME"

    # Get space details
    SPACE_DETAILS=$(aws sagemaker describe-space --domain-id $DOMAIN_ID --space-name "$SPACE_NAME")

    # Get space status
    SPACE_STATUS=$(echo $SPACE_DETAILS | jq -r '.Status')
    echo "    Space Status: $SPACE_STATUS"
    
    # Get app status to determine VM status more accurately
    echo "    Checking VM status..."
    APP_STATUS=$(aws sagemaker list-apps --domain-id $DOMAIN_ID --space-name "$SPACE_NAME" --query "Apps[?AppType=='JupyterLab'].Status" --output text)
    
    if [ -z "$APP_STATUS" ]; then
      VM_STATUS="No JupyterLab app found"
    else
      # If there are multiple apps, take the first one
      VM_STATUS=$(echo $APP_STATUS | cut -d ' ' -f1)
    fi
    
    echo "    VM Status: $VM_STATUS"

    # Get the app type to check if it's JupyterLab
    APP_TYPE=$(echo $SPACE_DETAILS | jq -r '.SpaceSettings.JupyterLabAppSettings.DefaultResourceSpec.SageMakerImageArn')
    
    # If APP_TYPE is null or empty, try to get it from another field
    if [ "$APP_TYPE" == "null" ] || [ -z "$APP_TYPE" ]; then
      APP_TYPE=$(echo $SPACE_DETAILS | jq -r '.SpaceSettings.JupyterLabAppSettings.DefaultResourceSpec.SageMakerImageVersionArn')
    fi

    # Check if it's a JupyterLab environment
    if [ "$APP_TYPE" == "null" ] && [ "$SPACE_STATUS" != "Deleted" ]; then
      echo "    App Type: JupyterLab (default)"
      # Increment total JupyterLab count
      TOTAL_JUPYTERLAB_COUNT=$((TOTAL_JUPYTERLAB_COUNT+1))
    elif [ "$APP_TYPE" != "null" ] && [ -n "$APP_TYPE" ]; then
      echo "    App Type: JupyterLab (custom image)"
      # Increment total JupyterLab count
      TOTAL_JUPYTERLAB_COUNT=$((TOTAL_JUPYTERLAB_COUNT+1))
    else
      echo "    App Type: Not a JupyterLab environment or deleted"
      continue
    fi

    # Get the owner user profile name
    OWNER_USER_PROFILE_NAME=$(echo $SPACE_DETAILS | jq -r '.OwnershipSettings.OwnerUserProfileName')
    echo "    Owner: $OWNER_USER_PROFILE_NAME"

    # Increment the count for the owner user profile
    profile_counts[$OWNER_USER_PROFILE_NAME]=$((${profile_counts[$OWNER_USER_PROFILE_NAME]}+1))

    # Get instance type and details
    INSTANCE_TYPE=$(echo $SPACE_DETAILS | jq -r '.SpaceSettings.JupyterLabAppSettings.DefaultResourceSpec.InstanceType')

    if [ "$INSTANCE_TYPE" != "null" ] && [ -n "$INSTANCE_TYPE" ]; then
      echo "    Instance Type: $INSTANCE_TYPE"
      
      # Get instance specifications
      INSTANCE_SPECS=$(get_instance_specs "$INSTANCE_TYPE")
      echo "    $INSTANCE_SPECS"
      
      # Store the instance details for the user profile
      profile_instances[$OWNER_USER_PROFILE_NAME]+="Domain: $DOMAIN_NAME (ID: $DOMAIN_ID), Space: $SPACE_NAME, Instance: $INSTANCE_TYPE, VM Status: $VM_STATUS, $INSTANCE_SPECS\n"
      
      # Increment running/stopped count based on VM status
      if [ "$VM_STATUS" == "InService" ]; then
        RUNNING_JUPYTERLAB_COUNT=$((RUNNING_JUPYTERLAB_COUNT+1))
      else
        STOPPED_JUPYTERLAB_COUNT=$((STOPPED_JUPYTERLAB_COUNT+1))
      fi
    else
      echo "    Instance: Not specified or stopped"
      
      # Store the instance details for the user profile
      profile_instances[$OWNER_USER_PROFILE_NAME]+="Domain: $DOMAIN_NAME (ID: $DOMAIN_ID), Space: $SPACE_NAME, VM Status: $VM_STATUS, Instance: Not specified\n"
      
      # Increment stopped count
      STOPPED_JUPYTERLAB_COUNT=$((STOPPED_JUPYTERLAB_COUNT+1))
    fi
  done

  # Print the counts and instance details for each user profile in this domain
  echo "==================================================="
  echo "User Profile Summary for Domain: $DOMAIN_NAME"
  echo "==================================================="
  for profile in "${!profile_counts[@]}"; do
    echo "User Profile: $profile, Instance Count: ${profile_counts[$profile]}"
    echo -e "Instance Details:\n${profile_instances[$profile]}"
    echo ""
  done
done

echo "==================================================="
echo "Overall Summary:"
echo "Total JupyterLab Environments: $TOTAL_JUPYTERLAB_COUNT"
echo "Running: $RUNNING_JUPYTERLAB_COUNT"
echo "Stopped: $STOPPED_JUPYTERLAB_COUNT"
echo "==================================================="