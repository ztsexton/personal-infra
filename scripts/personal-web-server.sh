#!/bin/bash
: "${SSH_USER:?Please set SSH_USER (e.g. export SSH_USER=ubuntu)}"

ssh -i mykey.ssh "$SSH_USER"@5.161.81.57