// ComplianceChecklistSheet.swift
// Clio
//
// One-time compliance checklist that must be confirmed before the first
// upload. Sourced from the NAV routine for midlertidig lagring av
// innsiktsdata (ref. PVK 25/35628). See US-FM-15.
//
// Note: not currently wired into the upload flow (no call site yet) —
// available for a future gate, kept project-agnostic since Clio has no
// "project" concept.

import SwiftUI

struct ComplianceChecklistSheet: View {

    /// Called once compliance is confirmed.
    let onConfirmed: () -> Void
    let onCancel: () -> Void

    @State private var checked: Set<Int> = []

    private let items: [(text: String, detail: String)] = [
        (
            "Deltakerne er informert om innsiktsarbeidet og har gitt gyldig samtykke",
            "Alle deltakere skal ha mottatt informasjon om prosjektet og gitt skriftlig samtykke i henhold til Datatilsynets krav."
        ),
        (
            "Ingen deltakere med kode 6 eller 7 er inkludert i datamaterialet",
            "Kode 6 (strengt fortrolig) og kode 7 (fortrolig) må aldri inngå i innsiktsarbeid."
        ),
        (
            "Ingen deltakere under 18 år er inkludert",
            "Mindreårige kan ikke delta i NAV-innsiktsprosjekter uten særskilt godkjenning."
        ),
        (
            "Lydopptak er godkjent gjennom risikovurdering og annen relevant dokumentasjon",
            "Risikovurdering (DPIA) for lydopptak skal være gjennomført og godkjent."
        ),
        (
            "Ingen video eller bilder av deltakere er inkludert",
            "Video og bilder av deltakere er ikke tillatt i midlertidig lagring på Teams."
        ),
        (
            "En datahåndteringsplan er på plass og oppdatert",
            "Datahåndteringsplanen skal dokumentere formål, behandlingsgrunnlag og planlagt sletting."
        )
    ]

    private var allChecked: Bool { checked.count == items.count }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(AppColors.accent)
                Text("Bekreft krav før opplasting")
                    .font(AppFont.screenTitle)
            }
            .padding(.top, AppSpacing.xl)
            .padding(.bottom, AppSpacing.lg)

            Divider()

            // Checklist
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        ChecklistItemRow(
                            text: item.text,
                            detail: item.detail,
                            isChecked: checked.contains(index)
                        ) {
                            if checked.contains(index) {
                                checked.remove(index)
                            } else {
                                checked.insert(index)
                            }
                        }
                    }
                }
                .padding(AppSpacing.xl)
            }

            Divider()

            // Footer
            VStack(spacing: AppSpacing.sm) {
                if !allChecked {
                    Text("Alle punkter må bekreftes for å fortsette")
                        .font(AppFont.tableCell)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: AppSpacing.md) {
                    Button("Avbryt", action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                    Button("Bekreft krav") {
                        confirm()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allChecked)
                }
            }
            .padding(AppSpacing.xl)
        }
        .frame(width: 540, height: 580)
    }

    private func confirm() {
        AuditLogger.shared.logComplianceCheckConfirmed()
        onConfirmed()
    }
}

// MARK: - ChecklistItemRow

private struct ChecklistItemRow: View {
    let text: String
    let detail: String
    let isChecked: Bool
    let onToggle: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isChecked ? AppColors.success : Color.secondary)
                        .animation(.easeInOut(duration: 0.15), value: isChecked)

                    Text(text)
                        .font(AppFont.tableCell)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(AppSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .fill(isChecked ? AppColors.success.opacity(0.06) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.15), value: isChecked)
    }
}
