// UploadConfirmationSheet.swift
// Clio
//
// Shown when the researcher taps "Last opp". Lets the researcher:
//   1. See exactly what filename will appear on Teams
//   2. Confirm the anonymization responsibility checkbox
//   3. Read the 8-month Teams retention reminder
//   4. Tap "Bekreft og last opp" to proceed
//
// Clio has no "project" concept — there's exactly one configured Teams
// channel every upload goes to, so there's nothing to pick or confirm here.

import SwiftUI

struct UploadConfirmationSheet: View {

    let recording: RecordingMeta
    /// Called with the remote filename when confirmed.
    let onConfirmed: (String) -> Void
    let onCancel: () -> Void

    @State private var anonymizationConfirmed = false

    private var remoteName: String {
        UploadGate.remoteName(displayName: recording.displayName, createdAt: recording.createdAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.to.line.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(AppColors.accent)
                Text("Last opp til Teams")
                    .font(AppFont.screenTitle)
            }
            .padding(.top, AppSpacing.xl)
            .padding(.bottom, AppSpacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {

                    // File preview
                    filePreviewSection(remoteName: remoteName)

                    // Anonymization confirmation
                    anonymizationSection

                    // Retention warning
                    retentionWarningSection
                }
                .padding(AppSpacing.xl)
            }

            Divider()

            // Actions
            HStack(spacing: AppSpacing.md) {
                Button("Avbryt", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Button("Bekreft og last opp") {
                    onConfirmed(remoteName)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!anonymizationConfirmed)
            }
            .padding(AppSpacing.xl)
        }
        .frame(width: 480)
    }

    // MARK: - Sections

    private func filePreviewSection(remoteName: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("Filnavn på Teams", systemImage: "doc.text")
                .font(AppFont.pillLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(AppColors.accent)
                Text(remoteName)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            .padding(AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private var anonymizationSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Label("Bekreftelse", systemImage: "lock.shield")
                .font(AppFont.pillLabel)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Button {
                anonymizationConfirmed.toggle()
            } label: {
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    Image(systemName: anonymizationConfirmed ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18))
                        .foregroundStyle(anonymizationConfirmed ? AppColors.success : Color.secondary)
                        .animation(.easeInOut(duration: 0.12), value: anonymizationConfirmed)

                    Text("Jeg bekrefter at transkripsjonen er avidentifisert og ikke inneholder personidentifiserbare opplysninger")
                        .font(AppFont.tableCell)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var retentionWarningSection: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 16))
                .foregroundStyle(AppColors.warning)

            VStack(alignment: .leading, spacing: 4) {
                Text("Midlertidig lagring")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.warning)
                Text("Filer på Teams slettes automatisk etter 8 måneder. Teams er midlertidig lagring — ikke et arkiv. Sørg for at materialet er behandlet og arkivert i henhold til prosjektplanen før sletting.")
                    .font(AppFont.tableCell)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .fill(AppColors.warning.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.medium)
                        .stroke(AppColors.warning.opacity(0.25), lineWidth: 1)
                )
        )
    }
}
