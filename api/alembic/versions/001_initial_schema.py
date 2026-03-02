"""Initial schema baseline — captures existing tables.

Revision ID: 001
Revises: None
Create Date: 2026-03-02
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Users
    op.create_table(
        "users",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("email", sa.Text, unique=True, nullable=False),
        sa.Column("password_hash", sa.Text, nullable=False),
        sa.Column("display_name", sa.Text, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        if_not_exists=True,
    )

    # API keys
    op.create_table(
        "api_keys",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("key_hash", sa.Text, unique=True, nullable=False),
        sa.Column("name", sa.Text, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("last_used", sa.DateTime(timezone=True)),
        if_not_exists=True,
    )

    # Notes
    op.create_table(
        "notes",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("user_id", sa.Text, nullable=False),
        sa.Column("path", sa.Text, nullable=False),
        sa.Column("title", sa.Text, nullable=False, server_default=""),
        sa.Column("content", sa.Text, nullable=False, server_default=""),
        sa.Column("folder", sa.Text, nullable=False, server_default=""),
        sa.Column("tags", sa.ARRAY(sa.Text), nullable=False, server_default="{}"),
        sa.Column("mtime", sa.Float, nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("user_id", "path"),
        if_not_exists=True,
    )

    op.create_index("idx_notes_user_folder", "notes", ["user_id", "folder"],
                     postgresql_where=sa.text("deleted_at IS NULL"), if_not_exists=True)
    op.create_index("idx_notes_user_updated", "notes", ["user_id", "updated_at"],
                     postgresql_where=sa.text("deleted_at IS NULL"), if_not_exists=True)
    op.create_index("idx_notes_user_tags", "notes", ["tags"],
                     postgresql_using="gin",
                     postgresql_where=sa.text("deleted_at IS NULL"), if_not_exists=True)

    # Attachments
    op.create_table(
        "attachments",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("user_id", sa.Text, nullable=False),
        sa.Column("path", sa.Text, nullable=False),
        sa.Column("content", sa.LargeBinary, nullable=False, server_default=sa.text("''")),
        sa.Column("mime_type", sa.Text, nullable=False, server_default="application/octet-stream"),
        sa.Column("size_bytes", sa.BigInteger, nullable=False, server_default="0"),
        sa.Column("mtime", sa.Float, nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("user_id", "path"),
        if_not_exists=True,
    )

    op.create_index("idx_attachments_user_updated", "attachments", ["user_id", "updated_at"],
                     if_not_exists=True)


def downgrade() -> None:
    op.drop_table("attachments")
    op.drop_table("notes")
    op.drop_table("api_keys")
    op.drop_table("users")
