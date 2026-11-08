-- Fake enterprise schema of the mock Enterprise System (ADR-0003): hire-purchase Contracts and their Payments.
-- Applied to the CURRENT database (enterprise_dev, enterprise_prod, or a test database) and safe to re-run.
-- Used by the mssql pod's schema container (deploy/thirdparty/mssql) and by the Seam-2 tests of
-- eshop-sync-master (pkhamdee/eshop-api: tests/Eshop.SyncMaster.Tests/enterprise-schema.sql, the source of truth;
-- pkhamdee/eshop-infra's deploy/thirdparty/mssql holds a copy its CI keeps identical), so both see the same schema.
--
-- Ownership (ADR-0001): rows in hp_contract are inserted by eshop-sync-master (push, idempotent on
-- contract_no) and from then on changed only here (the admin tool simulates Payments and cancellations).
-- Watermarks for the pull (#10): every row has `row_ver` (rowversion: increases on every insert/update,
-- database-wide) and `last_updated_at` (UTC, maintained by triggers). Pull "changed since" with
-- `WHERE row_ver > @last_seen` (and remember MAX(row_ver)).

IF SCHEMA_ID(N'hp') IS NULL EXEC (N'CREATE SCHEMA hp');
GO

IF OBJECT_ID(N'hp.contract', N'U') IS NULL
CREATE TABLE hp.contract
(
    contract_no        varchar(16)    NOT NULL CONSTRAINT pk_hp_contract PRIMARY KEY,
    source_system      varchar(10)    NOT NULL CONSTRAINT df_hp_contract_source DEFAULT ('ESHOP'),
    customer_id_no     char(13)       NOT NULL,
    customer_name      nvarchar(200)  NOT NULL,
    customer_mobile_no varchar(10)    NOT NULL,
    product_name       nvarchar(200)  NOT NULL,
    cash_price         decimal(12, 2) NOT NULL,
    down_payment       decimal(12, 2) NOT NULL,
    flat_rate          decimal(6, 4)  NOT NULL,
    term_months        int            NOT NULL,
    installment_amount decimal(12, 2) NOT NULL,
    total_payable      decimal(12, 2) NOT NULL,
    contract_date      datetimeoffset NOT NULL,
    -- ACTIVE | OVERDUE | PAID_OFF | CANCELLED
    status             varchar(10)    NOT NULL CONSTRAINT df_hp_contract_status DEFAULT ('ACTIVE')
                                      CONSTRAINT ck_hp_contract_status CHECK (status IN ('ACTIVE', 'OVERDUE', 'PAID_OFF', 'CANCELLED')),
    cancelled_at       datetimeoffset NULL,
    cancel_reason      nvarchar(200)  NULL,
    received_at        datetime2(3)   NOT NULL CONSTRAINT df_hp_contract_received DEFAULT (SYSUTCDATETIME()),
    last_updated_at    datetime2(3)   NOT NULL CONSTRAINT df_hp_contract_updated DEFAULT (SYSUTCDATETIME()),
    row_ver            rowversion     NOT NULL
);
GO

-- Databases created before the rename to eShop (#50) have another source_system default: bring it up to date.
IF EXISTS (SELECT 1 FROM sys.default_constraints
           WHERE name = N'df_hp_contract_source' AND parent_object_id = OBJECT_ID(N'hp.contract')
             AND definition <> N'(''ESHOP'')')
BEGIN
    ALTER TABLE hp.contract DROP CONSTRAINT df_hp_contract_source;
    ALTER TABLE hp.contract ADD CONSTRAINT df_hp_contract_source DEFAULT ('ESHOP') FOR source_system;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_hp_contract_row_ver')
    CREATE INDEX ix_hp_contract_row_ver ON hp.contract (row_ver);
GO

IF OBJECT_ID(N'hp.payment', N'U') IS NULL
CREATE TABLE hp.payment
(
    payment_id      bigint IDENTITY (1, 1) NOT NULL CONSTRAINT pk_hp_payment PRIMARY KEY,
    contract_no     varchar(16)    NOT NULL CONSTRAINT fk_hp_payment_contract REFERENCES hp.contract (contract_no),
    installment_no  int            NULL,
    amount          decimal(12, 2) NOT NULL CONSTRAINT ck_hp_payment_amount CHECK (amount > 0),
    paid_at         datetimeoffset NOT NULL,
    -- COUNTER | TRANSFER | PROMPTPAY
    channel         varchar(10)    NOT NULL CONSTRAINT df_hp_payment_channel DEFAULT ('COUNTER'),
    last_updated_at datetime2(3)   NOT NULL CONSTRAINT df_hp_payment_updated DEFAULT (SYSUTCDATETIME()),
    row_ver         rowversion     NOT NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_hp_payment_row_ver')
    CREATE INDEX ix_hp_payment_row_ver ON hp.payment (row_ver);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_hp_payment_contract_no')
    CREATE INDEX ix_hp_payment_contract_no ON hp.payment (contract_no);
GO

-- last_updated_at follows every update (rowversion does so by itself).
CREATE OR ALTER TRIGGER hp.tr_contract_touch ON hp.contract AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL() > 1 RETURN;
    UPDATE c SET last_updated_at = SYSUTCDATETIME()
    FROM hp.contract c JOIN inserted i ON i.contract_no = c.contract_no;
END;
GO

CREATE OR ALTER TRIGGER hp.tr_payment_touch ON hp.payment AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF TRIGGER_NESTLEVEL() > 1 RETURN;
    UPDATE p SET last_updated_at = SYSUTCDATETIME()
    FROM hp.payment p JOIN inserted i ON i.payment_id = p.payment_id;
END;
GO
