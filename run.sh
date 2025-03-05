#!/bin/bash

# List SageMaker Studio domains
echo "Listing SageMaker Studio domains..."
DOMAIN_INFO=$(aws sagemaker list-domains --query 'Domains[].{DomainId:DomainId, DomainName:DomainName}' --output json)

# Extract domain IDs and names from the JSON output
DOMAIN_IDS=$(echo $DOMAIN_INFO | jq -r '.[].DomainId')
DOMAIN_NAMES=$(echo $DOMAIN_INFO | jq -r '.[].DomainName')

IFS=$'\n' read -rd '' -a DOMAIN_ID_ARRAY <<< "$DOMAIN_IDS"
IFS=$'\n' read -rd '' -a DOMAIN_NAME_ARRAY <<< "$DOMAIN_NAMES"

for ((i=0; i<${#DOMAIN_ID_ARRAY[@]}; i++)); do
  DOMAIN_ID="${DOMAIN_ID_ARRAY[$i]}"
  DOMAIN_NAME="${DOMAIN_NAME_ARRAY[$i]}"
  echo "Domain ID: $DOMAIN_NAME - $DOMAIN_ID"

  # List spaces in the domain
  echo "Listing spaces in the domain..."
  SPACE_NAMES=$(aws sagemaker list-spaces --domain-id $DOMAIN_ID --query 'Spaces[].SpaceName' --output text)

  # Initialize a dictionary to store the counts and instance details for this domain
  declare -A profile_counts
  declare -A profile_instances

  for SPACE_NAME in $SPACE_NAMES; do
    echo "  Space Name: $SPACE_NAME"

    # Get space details
    echo "  Getting space details...aws sagemaker describe-space --domain-id $DOMAIN_ID --space-name \"$SPACE_NAME\""
	  SPACE_DETAILS=$(aws sagemaker describe-space --domain-id $DOMAIN_ID --space-name "$SPACE_NAME")

    # Get the owner user profile name
    echo "  Getting owner user profile name..."
    OWNER_USER_PROFILE_NAME=$(echo $SPACE_DETAILS | jq -r '.OwnershipSettings.OwnerUserProfileName')
    echo "    Owner User Profile Name: $OWNER_USER_PROFILE_NAME"

    # Increment the count for the owner user profile
    echo "  Incrementing count for user profile: $OWNER_USER_PROFILE_NAME"
    profile_counts[$OWNER_USER_PROFILE_NAME]=$((${profile_counts[$OWNER_USER_PROFILE_NAME]}+1))

    # Get instance type and details
    echo "  Getting instance type and details..."
    INSTANCE_TYPE=$(echo $SPACE_DETAILS | jq -r '.SpaceSettings.JupyterLabAppSettings.DefaultResourceSpec.InstanceType')
    echo "    Instance Type: $INSTANCE_TYPE"

    if [ "$INSTANCE_TYPE" != "null" ]; then
      echo "      Instance Type: $INSTANCE_TYPE"

      echo "      Getting instance type details..."
      INSTANCE_DETAILS=$(aws ec2 describe-instance-types --instance-types $INSTANCE_TYPE --query 'InstanceTypes[0]')

      CPU_INFO=$(echo $INSTANCE_DETAILS | jq -r '.VCpuInfo.DefaultVCpus')
      GPU_INFO=$(echo $INSTANCE_DETAILS | jq -r '.GpuInfo.Gpus[0].Count')

      echo "      CPU Info: $CPU_INFO"
      echo "      GPU Info: $GPU_INFO"

      # Store the instance details for the user profile
      profile_instances[$OWNER_USER_PROFILE_NAME]+="Domain ID: $DOMAIN_ID, Domain Name: $DOMAIN_NAME, Instance Type: $INSTANCE_TYPE, CPU: $CPU_INFO, GPU: $GPU_INFO\n"
    else
      echo "      Instance Stopped, skipping..."
    fi
  done

  # Print the counts and instance details for each user profile in this domain
  echo "Printing instance counts and details for each user profile in domain $DOMAIN_ID ($DOMAIN_NAME):"
  for profile in "${!profile_counts[@]}"; do
    echo "User Profile: $profile, Instance Count: ${profile_counts[$profile]}"
    echo -e "Instance Details:\n${profile_instances[$profile]}"
    echo ""
  done
done
