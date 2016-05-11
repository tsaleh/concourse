#!/usr/bin/env bash

set -e -x

mkdir -p ~/.aws

cat << EOF > ~/.aws/config
[default]
output = json
region = us-east-1
EOF

VPC_CIDR_BLOCK="10.0.0.0/16"
SUBNET_CIDR_BLOCK="10.0.0.0/24"
KEY_NAME="cm-cd-$(uuidgen)"
aws ec2 wait image-exists --image-ids $IMAGE_ID

set +x
aws ec2 create-key-pair --key-name $KEY_NAME | jq ".KeyMaterial" | tr -ds '"' '' > escaped_key
echo -e $(cat escaped_key) > id_rsa
rm -f escaped_key
chmod 0400 id_rsa
rm -f id_rsa
set -x

VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR_BLOCK | jq ".Vpc.VpcId" | tr -ds '"' '')
aws ec2 wait vpc-available --vpc-ids $VPC_ID

SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR_BLOCK | jq ".Subnet.SubnetId" | tr -ds '"' '')
aws ec2 wait subnet-available --subnet-ids $SUBNET_ID

ip_info=$(aws ec2 allocate-address)
IP=$(echo $ip_info | jq ".PublicIp" | tr -ds '"' '')
ALLOCATION_ID=$(echo $ip_info | jq ".AllocationId" | tr -ds '"' '')

GATEWAY_ID=$(aws ec2 create-internet-gateway | jq ".InternetGateway.InternetGatewayId" | tr -ds '"' '')
aws ec2 attach-internet-gateway --internet-gateway-id $GATEWAY_ID --vpc-id $VPC_ID

ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" | jq ".RouteTables[0].RouteTableId" | tr -ds '"' '')
aws ec2 create-route --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $GATEWAY_ID

SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name "concourse binary test security group" --description "concourse binary test security group" --vpc-id $VPC_ID | jq ".GroupId" | tr -ds '"' '')
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

INSTANCE_ID=$(aws ec2 run-instances --image-id $IMAGE_ID --key-name $KEY_NAME --security-group-ids $SECURITY_GROUP_ID --instance-type m4.large --subnet-id $SUBNET_ID | jq ".Instances[0].InstanceId" | tr -ds '"' '') 

function cleanup_account()
{
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
  aws ec2 release-address --allocation-id $ALLOCATION_ID
  aws ec2 delete-key-pair --key-name $KEY_NAME
  aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID
  aws ec2 delete-subnet --subnet-id $SUBNET_ID
  aws ec2 detach-internet-gateway --internet-gateway-id $GATEWAY_ID --vpc-id $VPC_ID
  aws ec2 delete-internet-gateway --internet-gateway-id $GATEWAY_ID
  aws ec2 delete-vpc --vpc-id $VPC_ID
}

trap cleanup_account ERR TERM INT

aws ec2 wait instance-running --instance-ids $INSTANCE_ID
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID

aws ec2 associate-address --instance-id $INSTANCE_ID --allocation-id $ALLOCATION_ID

ssh -i id_rsa -o StrictHostKeyChecking=no ubuntu@$IP 'exit 0'

cleanup_account

