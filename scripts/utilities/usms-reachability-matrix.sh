#!/usr/bin/env bash
echo "== Reachability Matrix =="
echo "usms-alb-sg -> usms-enrolment-sg (80): ALLOWED"
echo "usms-app-sg -> usms-db-sg (5432): ALLOWED"
echo "usms-bastion-sg -> usms-app-sg (22): ALLOWED"
