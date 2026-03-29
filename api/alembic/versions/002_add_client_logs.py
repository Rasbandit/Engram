"""Add client_logs table for remote plugin debugging.

Revision ID: 002
Revises: 001
Create Date: 2026-03-28
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "002"
down_revision: Union[str, None] = "001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "client_logs",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("user_id", sa.Text, nullable=False),
        sa.Column("ts", sa.DateTime(timezone=True), nullable=False),
        sa.Column("level", sa.Text, nullable=False, server_default="info"),
        sa.Column("category", sa.Text, nullable=False, server_default=""),
        sa.Column("message", sa.Text, nullable=False, server_default=""),
        sa.Column("stack", sa.Text),
        sa.Column("plugin_version", sa.Text, nullable=False, server_default=""),
        sa.Column("platform", sa.Text, nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        if_not_exists=True,
    )

    op.create_index("idx_client_logs_user_created", "client_logs", ["user_id", sa.text("created_at DESC")],
                     if_not_exists=True)
    op.create_index("idx_client_logs_user_level", "client_logs", ["user_id", "level"],
                     if_not_exists=True)


def downgrade() -> None:
    op.drop_table("client_logs")
