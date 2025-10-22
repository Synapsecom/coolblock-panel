-- Create the database
CREATE DATABASE IF NOT EXISTS `coolblock-panel`;

-- Use the created database
USE `coolblock-panel`;

-- Create the sys table
CREATE TABLE IF NOT EXISTS `sys` (
    `id` INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `version` VARCHAR(10) NOT NULL UNIQUE DEFAULT '0.0.0',
    `sn` VARCHAR(36) NOT NULL UNIQUE DEFAULT '00000000-0000-0000-0000-000000000000',
    `tank` VARCHAR(10) NOT NULL UNIQUE DEFAULT 'undefined',
    `plc` VARCHAR(39) NOT NULL UNIQUE DEFAULT '10.13.37.11',
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Add indexes for faster lookups (optimized to remove redundancy)
-- Only keeping plc index as it's not covered by composite index
ALTER TABLE
    `sys`
ADD
    INDEX idx_plc (`plc`);

-- Composite index for common multi-column queries - covers sn, tank, version lookups
ALTER TABLE
    `sys`
ADD
    INDEX idx_sn_tank_version (`sn`, `tank`, `version`);

-- Create the users table
CREATE TABLE IF NOT EXISTS `users` (
    `id` INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `username` VARCHAR(50) NOT NULL UNIQUE,
    `password` VARCHAR(255) NOT NULL,
    `pin` CHAR(4) NOT NULL,
    `role` ENUM('admin', 'user') NOT NULL DEFAULT 'user',
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Add indexes for faster lookups
ALTER TABLE
    `users`
ADD
    INDEX idx_username (`username`);

-- Composite index for authentication and role-based queries
ALTER TABLE
    `users`
ADD
    INDEX idx_username_role (`username`, `role`);

-- Index for user management pagination
ALTER TABLE
    `users`
ADD
    INDEX idx_created_at_desc (`created_at` DESC);

-- Insert initial user
INSERT INTO
    `users` (`username`, `password`, `pin`, `role`)
VALUES
    (
        'admin',
        '$2b$10$LvpEN9Q4plWY.qyhBIHToOKYPyCyTsiiAMj7GrGZhUcv4ByNZiIei',
        '1234',
        'admin'
    );

-- Safe mechanism in the deletion of default admin user
DROP TRIGGER IF EXISTS users_block_delete_admin;
DELIMITER $$

CREATE TRIGGER users_block_delete_admin
BEFORE DELETE ON `users`
FOR EACH ROW
BEGIN
  IF LOWER(OLD.username) IN ('admin','portal') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Protected user cannot be deleted.';
  END IF;
END$$

DELIMITER ;

-- Safe mechanism for password change of user : portal
DROP TRIGGER IF EXISTS users_block_update_portal_password;
DELIMITER $$

CREATE TRIGGER users_block_update_portal_password
BEFORE UPDATE ON `users`
FOR EACH ROW
BEGIN
  IF LOWER(OLD.username) = 'portal' AND NEW.password <> OLD.password THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Password change is not allowed for the portal user';
  END IF;
END$$

DELIMITER ;

-- Create the audit_logs table with partition (@mr.robot -> zabbix example)
CREATE TABLE `audit_logs` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `user` VARCHAR(64) NOT NULL,
    `action` VARCHAR(128) NOT NULL,
    `ip_address` VARCHAR(45) DEFAULT NULL,
    `timestamp` DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`, `timestamp`),
    -- Composite indexes for common query patterns
    INDEX idx_timestamp_user (`timestamp` DESC, `user`),
    INDEX idx_timestamp_action (`timestamp` DESC, `action`),
    INDEX idx_user_timestamp (`user`, `timestamp` DESC),
    INDEX idx_search_optimization (`timestamp` DESC, `user`, `action`, `ip_address`)
)
ENGINE = InnoDB
DEFAULT CHARSET = utf8mb4
COLLATE = utf8mb4_unicode_ci
ROW_FORMAT = COMPRESSED
PARTITION BY RANGE (YEAR(`timestamp`)*100 + MONTH(`timestamp`)) (
    PARTITION p202507 VALUES LESS THAN (202508),
    PARTITION pmax VALUES LESS THAN MAXVALUE
);

-- Stored Procedure for monthly partitioning
DELIMITER $$

CREATE PROCEDURE manage_audit_partitions(retention_months INT)
BEGIN
    DECLARE next_partition_value INT;
    DECLARE next_partition_name VARCHAR(20);
    DECLARE exists_count INT;

    DECLARE done INT DEFAULT FALSE;
    DECLARE part_name VARCHAR(64);
    DECLARE part_value INT;

    DECLARE cutoff_value INT;
    DECLARE cur CURSOR FOR
        SELECT PARTITION_NAME, PARTITION_DESCRIPTION
        FROM INFORMATION_SCHEMA.PARTITIONS
        WHERE TABLE_SCHEMA = 'coolblock-panel'
          AND TABLE_NAME = 'audit_logs'
          AND PARTITION_NAME NOT IN ('pmax');

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    -- Compute partition for next month
    SET next_partition_value = YEAR(CURRENT_DATE + INTERVAL 1 MONTH)*100
                             + MONTH(CURRENT_DATE + INTERVAL 1 MONTH);
    SET next_partition_name = CONCAT('p', next_partition_value);

    -- Check if partition exists
    SELECT COUNT(*)
    INTO exists_count
    FROM INFORMATION_SCHEMA.PARTITIONS
    WHERE TABLE_SCHEMA = 'coolblock-panel'
      AND TABLE_NAME = 'audit_logs'
      AND PARTITION_NAME = next_partition_name;

    IF exists_count = 0 THEN
        SET @stmt = CONCAT(
            'ALTER TABLE audit_logs ',
            'REORGANIZE PARTITION pmax INTO ( ',
            'PARTITION ', next_partition_name,
            ' VALUES LESS THAN (', next_partition_value + 1, '), ',
            'PARTITION pmax VALUES LESS THAN MAXVALUE)'
        );
        PREPARE stmt FROM @stmt;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END IF;

    SET cutoff_value = YEAR(DATE_SUB(CURRENT_DATE, INTERVAL retention_months MONTH)) * 100
                 + MONTH(DATE_SUB(CURRENT_DATE, INTERVAL retention_months MONTH));

    OPEN cur;

    read_loop: LOOP
        FETCH cur INTO part_name, part_value;
        IF done THEN
            LEAVE read_loop;
        END IF;

        IF part_value < cutoff_value THEN
            SET @stmt = CONCAT(
                'ALTER TABLE audit_logs DROP PARTITION ', part_name
            );
            PREPARE stmt FROM @stmt;
            EXECUTE stmt;
            DEALLOCATE PREPARE stmt;
        END IF;
    END LOOP;

    CLOSE cur;
END$$

DELIMITER ;

-- Schedule event (delete partition > 3)
-- Run once per month...
DELIMITER $$

CREATE EVENT IF NOT EXISTS manage_audit_event
ON SCHEDULE EVERY 1 MONTH
STARTS TIMESTAMP(CURRENT_DATE + INTERVAL 1 MONTH)
DO
BEGIN
    CALL manage_audit_partitions(3);
END$$

DELIMITER ;

-- Create Notification Configuration table
CREATE TABLE IF NOT EXISTS `notification_configuration` (
    `id` INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    `name` VARCHAR(16) NOT NULL,
    `type` ENUM('discord', 'slack', 'generic-http') NOT NULL,
    `url` VARCHAR(256) NOT NULL,
    `status` ENUM('ENABLED','DISABLED') NOT NULL DEFAULT 'ENABLED',
    `metadata` JSON DEFAULT NULL,
    `timestamp` DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Optimized composite indexes (removed redundant single-column indexes)
ALTER TABLE `notification_configuration` ADD INDEX idx_status_type_timestamp (`status`, `type`, `timestamp` DESC);
ALTER TABLE `notification_configuration` ADD INDEX idx_status_name (`status`, `name`);

-- Virtual columns for common JSON metadata queries (performance optimization)
ALTER TABLE `notification_configuration`
ADD COLUMN `webhook_url` VARCHAR(255) GENERATED ALWAYS AS (JSON_UNQUOTE(JSON_EXTRACT(`metadata`, '$.webhook_url'))) STORED,
ADD INDEX idx_webhook_url (`webhook_url`);

-- Create a reference table for alerts as a safe mechanism for the panel-web in creation alerts modal. (view only)
CREATE TABLE IF NOT EXISTS `alert_reference` (
  `name` VARCHAR(64) PRIMARY KEY,
  `comparison_mode` ENUM('THRESHOLD', 'MATCH') NOT NULL,
  `threshold_min` REAL DEFAULT NULL,
  `threshold_max` REAL DEFAULT NULL,
  `default_threshold` REAL DEFAULT NULL,
  `match_value` INT DEFAULT NULL,
  `threshold_type` ENUM('LOWER', 'UPPER', 'MATCH') NOT NULL,
  `unit` ENUM('deg_celsius', 'cubic_meter_per_hour', 'none') DEFAULT 'none'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Seed values
INSERT INTO `alert_reference` (`name`, `comparison_mode`, `threshold_min`, `threshold_max`, `default_threshold`, `match_value`, `threshold_type`, `unit`)
VALUES
('chiller_water_in', 'THRESHOLD', 20, 50, 30, NULL, 'UPPER', 'deg_celsius'),
('chiller_water_out', 'THRESHOLD', 20, 50, 40, NULL, 'UPPER', 'deg_celsius'),
('chiller_water_flow', 'THRESHOLD', 0, 4, 0.5, NULL, 'LOWER', 'cubic_meter_per_hour'),
('cdu_coolant_in', 'THRESHOLD', 20, 50, 40, NULL, 'UPPER', 'deg_celsius'),
('cdu_coolant_out', 'THRESHOLD', 20, 50, 40, NULL, 'UPPER', 'deg_celsius'),
('cdu_coolant_flow', 'THRESHOLD', 0, 12, 4, NULL, 'LOWER', 'cubic_meter_per_hour'),
('coolant_conductivity_status', 'MATCH', NULL, NULL, NULL, 2, 'MATCH', 'none'),
('coolant_point_level_status', 'MATCH', NULL, NULL, NULL, 1, 'MATCH', 'none'),
('pump1_error', 'MATCH', NULL, NULL, NULL, 1, 'MATCH', 'none'),
('pump2_error', 'MATCH', NULL, NULL, NULL, 1, 'MATCH', 'none'),
('lid_is_open', 'MATCH', NULL, NULL, NULL, 1, 'MATCH', 'none');

-- Create the alert_configuration table
CREATE TABLE IF NOT EXISTS `alert_configuration` (
  `id` INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  `name` ENUM(
    'chiller_water_in',
    'chiller_water_out',
    'chiller_water_flow',
    'cdu_coolant_in',
    'cdu_coolant_out',
    'cdu_coolant_flow',
    'coolant_conductivity_status',
    'coolant_point_level_status',
    'pump1_error',
    'pump2_error',
    'lid_is_open'
  ) NOT NULL,
  `comparison_mode` ENUM('THRESHOLD', 'MATCH') NOT NULL DEFAULT 'THRESHOLD',
  `threshold` REAL DEFAULT NULL,
  `threshold_min` REAL DEFAULT NULL,
  `threshold_max` REAL DEFAULT NULL,
  `match_value` INT DEFAULT NULL,
  `threshold_type` ENUM('LOWER', 'UPPER', 'MATCH')  NOT NULL DEFAULT 'UPPER',
  `unit` ENUM('deg_celsius', 'cubic_meter_per_hour', 'none') DEFAULT 'none',
  `severity` ENUM('WARNING', 'CRITICAL') NOT NULL,
  `notification_type` ENUM('LOCAL', 'REMOTE') NOT NULL DEFAULT 'LOCAL',
  `notification_id` INT UNSIGNED DEFAULT NULL,
  `status` ENUM('ENABLED','DISABLED') NOT NULL DEFAULT 'ENABLED',
  `timestamp` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT `fk_notification_config`
    FOREIGN KEY (`notification_id`) REFERENCES `notification_configuration`(`id`)
    ON DELETE SET NULL
    ON UPDATE CASCADE
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Optimized indexes (removed redundant single-column indexes covered by composite indexes)
-- Main covering index for most queries (covers status, name, severity, notification_id)
ALTER TABLE `alert_configuration` ADD INDEX idx_covering_main (`status`, `name`, `severity`, `notification_id`, `timestamp`, `id`);
-- For unique alerts query (MAX(id) GROUP BY name) - critical for your API
ALTER TABLE `alert_configuration` ADD INDEX idx_name_id (`name`, `id` DESC);
-- For JOIN optimization with notification_configuration
ALTER TABLE `alert_configuration` ADD INDEX idx_notification_status (`notification_id`, `status`);
-- For timestamp-based ordering (DESC for recent first)
ALTER TABLE `alert_configuration` ADD INDEX idx_timestamp_desc (`timestamp` DESC, `id` DESC);

-- Safety trigger for notification configuration consistency
DELIMITER $$
CREATE TRIGGER validate_alert_notification_insert
BEFORE INSERT ON alert_configuration
FOR EACH ROW
BEGIN
  IF (NEW.notification_type = 'REMOTE' AND NEW.notification_id IS NULL)
     OR (NEW.notification_type = 'LOCAL' AND NEW.notification_id IS NOT NULL) THEN
    SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Invalid combination: REMOTE must have notification_id, LOCAL must not.';
  END IF;
END$$
DELIMITER ;

-- Safety set mechanism for measurement unit
DELIMITER $$

CREATE TRIGGER set_unit_before_insert
BEFORE INSERT ON alert_configuration
FOR EACH ROW
BEGIN
  CASE
    WHEN NEW.name IN ('chiller_water_in', 'chiller_water_out', 'cdu_coolant_in', 'cdu_coolant_out')
      THEN SET NEW.unit = 'deg_celsius';
    WHEN NEW.name IN ('chiller_water_flow', 'cdu_coolant_flow')
      THEN SET NEW.unit = 'cubic_meter_per_hour';
    WHEN NEW.name IN ('coolant_conductivity_status', 'coolant_point_level_status', 'pump1_error', 'pump2_error', 'lid_is_open')
      THEN SET NEW.unit = 'none';
    ELSE
      SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Unknown alert name for unit assignment';
  END CASE;
END$$

DELIMITER ;

-- Safety set mechanism for threshold type per alert name
DELIMITER $$

CREATE TRIGGER set_threshold_type_before_insert
BEFORE INSERT ON alert_configuration
FOR EACH ROW
BEGIN
  CASE
    WHEN NEW.name IN ('coolant_conductivity_status', 'coolant_point_level_status', 'pump1_error', 'pump2_error', 'lid_is_open')
      THEN SET NEW.threshold_type = 'MATCH';

    WHEN NEW.name IN ('chiller_water_in', 'chiller_water_out', 'cdu_coolant_in', 'cdu_coolant_out')
      THEN SET NEW.threshold_type = 'UPPER';

    WHEN NEW.name IN ('chiller_water_flow', 'cdu_coolant_flow')
      THEN SET NEW.threshold_type = 'LOWER';

    ELSE
      SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Unknown alert name for threshold_type mapping';
  END CASE;
END$$

DELIMITER ;
