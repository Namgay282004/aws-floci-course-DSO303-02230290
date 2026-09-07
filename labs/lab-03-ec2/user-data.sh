#!/bin/bash
sudo yum update -y
sudo yum install -y nginx
sudo systemctl enable --now nginx
