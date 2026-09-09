import SwiftUI

struct MethodologySplash: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Assistant Editor — Reference")
                    .scaledFont(.title2).bold()
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Group {
                        Text("Resolve Workflow")
                            .scaledFont(.headline)
                            .foregroundColor(.accentColor)
                        workflowStep("1", "Sync audio & video for each interview")
                        workflowStep("2", "Transcribe the entire timeline (Resolve's speech-to-text)")
                        workflowStep("3", "Assign speakers to each voice")
                        workflowStep("4", "Export transcript (_transcript.txt or _transcripts.txt) — paragraph-level with timecodes")
                        workflowStep("5", "Export subtitles (_subtitles.srtx or .srt) — granular 2-10s cues")
                    }

                    Divider()

                    Group {
                        Text("Project Setup Tab")
                            .scaledFont(.headline)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 6) {
                            dot("Add folders containing your subtitle/transcript files")
                            dot("Analyze Project extracts themes, keywords, and weights via LLM")
                            dot("Theme weights (sliders) control how chapters are allocated across topics")
                            dot("Adjust weights to reflect your editorial priorities before processing")
                            dot("Create Chapters works from subtitles alone — a transcript is optional")
                        }
                    }

                    Divider()

                    Group {
                        Text("Timeline Assist Tab")
                            .scaledFont(.headline)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 6) {
                            dot("Chapter Density — low creates few long chapters, high creates many short ones")
                            dot("Chapter Verbosity — controls detail level of chapter notes")
                            dot("Synopsis Verbosity — controls detail level of the synopsis document")
                            dot("Search Source — switch between Subtitles (precise clips) and Transcripts (thematic context)")
                            dot("Prompt bar interprets natural language into search keywords via LLM")
                            dot("Looser/Tighter slider adjusts semantic similarity threshold")
                            dot("Create Timeline sends selected clips to DaVinci Resolve")
                        }
                    }

                    Divider()

                    Group {
                        Text("Transcript Intelligence Tab")
                            .scaledFont(.headline)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 6) {
                            dot("Independent folder picker — select project folders for the chat")
                            dot("RAG chat grounded in your interview data via KnowledgeStore + FTS5 search")
                            dot("Ask questions about themes, speakers, content across all interviews")
                        }
                    }

                    Divider()

                    Group {
                        Text("Keyboard Shortcuts")
                            .scaledFont(.headline)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 6) {
                            dot("⌘1 / ⌘2 / ⌘3 / ⌘4 — switch tabs")
                            dot("⌘+ / ⌘- — change app-wide text size")
                            dot("⌘0 — reset text size to default")
                            dot("⌘, — open Priming (one editable prompt per LLM step)")
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            VStack(spacing: 4) {
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                Text("Assistant Editor v1.21")
                    .foregroundColor(.secondary)
                    .scaledFont(.caption)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .frame(width: 480, height: 520)
        .background(
            Button("") { isPresented = false }
                .keyboardShortcut(.escape)
                .opacity(0)
        )
    }

    @ViewBuilder
    func workflowStep(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .scaledFont(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text).foregroundColor(.primary)
        }
    }

    @ViewBuilder
    func dot(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(.accentColor)
            Text(text).foregroundColor(.secondary)
        }
    }
}
