package main

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Listen      string         `yaml:"listen"`       // 代理监听端口
	AdminListen string         `yaml:"admin_listen"`  // 管理后台端口
	AdminPass   string         `yaml:"admin_pass"`   // 管理后台密码
	DBPath      string         `yaml:"db_path"`      // SQLite 数据库路径
	Reverse     *ReverseConfig `yaml:"reverse"`      // DNS 直连模式反向代理
}

// ReverseConfig DNS 直连模式反向代理配置
type ReverseConfig struct {
	Enabled     bool   `yaml:"enabled"`      // 是否启用
	Listen      string `yaml:"listen"`       // 监听地址，如 ":443"
	CertFile    string `yaml:"cert_file"`    // 服务器证书（api.anthropic.com）
	KeyFile     string `yaml:"key_file"`     // 服务器私钥
	CAFile      string `yaml:"ca_file"`      // CA 证书（验证客户端 mTLS）
	RequireMTLS bool   `yaml:"require_mtls"` // 是否要求客户端证书
	Backend     string `yaml:"backend"`      // 可选：上游代理 URL
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if cfg.Listen == "" {
		cfg.Listen = ":8080"
	}
	if cfg.AdminListen == "" {
		cfg.AdminListen = ":8081"
	}
	if cfg.AdminPass == "" {
		cfg.AdminPass = "admin"
	}
	if cfg.DBPath == "" {
		cfg.DBPath = "anideaai-server.db"
	}
	return &cfg, nil
}
