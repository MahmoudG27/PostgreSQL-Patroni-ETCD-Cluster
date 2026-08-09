#!/bin/bash

set -e

# Create Load Balancer:
az network lb create \
  --resource-group <اسم-الـ-resource-group> \
  --name pg-ha-lb \
  --sku Standard \
  --vnet-name <اسم-الـ-VNet> \
  --subnet <اسم-الـ-Subnet> \
  --frontend-ip-name pg-frontend \
  --private-ip-address 10.0.1.100 \
  --backend-pool-name pg-backend-pool


# Add the 5 VMs to the Backend Pool:
az network nic ip-config address-pool add \
  --resource-group <اسم-الـ-resource-group> \
  --nic-name <NIC-بتاع-pg-node1> \
  --ip-config-name ipconfig1 \
  --lb-name pg-ha-lb \
  --address-pool pg-backend-pool
# Repeat the same command for pg-node2 and pg-node3 (just change --nic-name).


# Create a health probe for PostgreSQL:
az network lb probe create \
  --resource-group <اسم-الـ-resource-group> \
  --lb-name pg-ha-lb \
  --name patroni-health-probe \
  --protocol http \
  --port 8008 \
  --path /primary \
  --interval 5 \
  --threshold 2


# Create a Load Balancing Rule for PostgreSQL:
az network lb rule create \
  --resource-group <اسم-الـ-resource-group> \
  --lb-name pg-ha-lb \
  --name pg-lb-rule \
  --protocol tcp \
  --frontend-port 5432 \
  --backend-port 5432 \
  --frontend-ip-name pg-frontend \
  --backend-pool-name pg-backend-pool \
  --probe-name patroni-health-probe


# Check the Load Balancer Backend Pool to ensure all 5 VMs are correctly added:
az network lb address-pool show \
  --resource-group <اسم-الـ-RG> \
  --lb-name pg-ha-lb \
  --name pg-backend-pool


# Test to connect postgresql using the Load Balancer:
psql -h 10.0.1.100 -p 5432 -U postgres -d postgres

# Change 10.0.1.100 with Frontend IP you assigned to the Load Balancer.