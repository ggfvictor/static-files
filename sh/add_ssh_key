#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 用户运行此脚本。"
  exit 1
fi

# 定义要添加的 SSH 公钥
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOpxyoQ6pQ7+ikdCPgyBg+54NTivQZlNAbJFrBqSx5Uy"

# 检查 /root/.ssh 目录是否存在，不存在则创建
if [ ! -d /root/.ssh ]; then
  mkdir -p /root/.ssh
  if [ $? -eq 0 ]; then
    echo "/root/.ssh 目录已创建。"
  else
    echo "无法创建 /root/.ssh 目录。"
    exit 1
  fi
fi

# 检查 authorized_keys 文件是否存在，不存在则创建
if [ ! -f /root/.ssh/authorized_keys ]; then
  touch /root/.ssh/authorized_keys
  if [ $? -eq 0 ]; then
    echo "/root/.ssh/authorized_keys 文件已创建。"
  else
    echo "无法创建 /root/.ssh/authorized_keys 文件。"
    exit 1
  fi
fi

# 检查公钥是否已经存在
grep -qF "$SSH_KEY" /root/.ssh/authorized_keys
if [ $? -eq 0 ]; then
  echo "SSH 公钥已经存在，未进行重复添加。"
else
  # 将公钥追加到 authorized_keys 文件
  echo "$SSH_KEY" >> /root/.ssh/authorized_keys
  if [ $? -eq 0 ]; then
    echo "SSH 公钥已成功添加。"
  else
    echo "添加 SSH 公钥失败。"
    exit 1
  fi
fi

# 设置权限
chmod 600 /root/.ssh/authorized_keys
chmod 700 /root/.ssh

if [ $? -eq 0 ]; then
  echo "权限设置已成功应用。"
else
  echo "权限设置失败。"
  exit 1
fi

echo "公钥添加完成并且权限配置成功。"
