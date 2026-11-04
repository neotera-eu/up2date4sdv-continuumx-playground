#!/bin/bash
# Restart edgecore so config patches are applied, then check it is active.

systemctl enable edgecore
systemctl restart edgecore
systemctl is-active --quiet edgecore
