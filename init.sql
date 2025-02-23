-- Create the database
CREATE DATABASE IF NOT EXISTS `coolblock-panel`;

-- Use the created database
USE `coolblock-panel`;

-- Create the sys table
CREATE TABLE IF NOT EXISTS `sys` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `version` VARCHAR(10) NOT NULL UNIQUE DEFAULT '0.0.0',
    `sn` VARCHAR(36) NOT NULL UNIQUE DEFAULT '00000000-0000-0000-0000-000000000000',
    `tank` VARCHAR(10) NOT NULL UNIQUE DEFAULT 'undefined',
    `plc` VARCHAR(39) NOT NULL UNIQUE DEFAULT '10.13.37.11',
    `last_modified` BIGINT NOT NULL UNIQUE DEFAULT 0
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

-- Create the users table
CREATE TABLE IF NOT EXISTS `users` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `username` VARCHAR(50) NOT NULL UNIQUE,
    `password` VARCHAR(255) NOT NULL,
    `pin` CHAR(4) NOT NULL,
    `role` ENUM('admin', 'user') NOT NULL DEFAULT 'user'
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COLLATE = utf8mb4_unicode_ci;

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
