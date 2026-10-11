import SwiftUI

/// The app follows Apple's system design: system text styles and colors, grouped lists,
/// and Liquid Glass controls. The tint is the label color (black in light mode, white in dark),
/// so emoji and people's photos carry the color.
enum Theme {
    static let cardRadius: CGFloat = 28
}

/// The partymate mark: two people (circles) at the same party, with the overlap filled in.
/// With `animatesIn`, the circles slide together once when it appears.
struct PartymateMark: View {
    var size: CGFloat = 112
    var animatesIn = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var together = false

    /// How far apart the circle centers are, as a fraction of the diameter.
    private var separation: CGFloat {
        animatesIn && !together ? 1.0 : 0.56
    }

    var body: some View {
        ZStack {
            MarkLens(separation: separation)
                .fill(Color.primary)
            MarkRings(separation: separation)
                .stroke(Color.primary, lineWidth: size * 0.065)
        }
        .frame(width: size * 1.6, height: size)
        .accessibilityHidden(true)
        // A light tap as the two circles meet.
        .sensoryFeedback(.impact(weight: .light), trigger: together)
        .onAppear {
            guard animatesIn else { return }
            if reduceMotion {
                together = true
            } else {
                withAnimation(.spring(duration: 0.5, bounce: 0.2).delay(0.05)) {
                    together = true
                }
            }
        }
    }
}

/// The two circles, side by side, centered in the rect.
private func markCircles(in rect: CGRect, separation: CGFloat) -> (CGRect, CGRect) {
    let d = rect.height * 0.92
    let gap = d * separation
    let midX = rect.midX
    let y = rect.midY - d / 2
    let left = CGRect(x: midX - gap / 2 - d / 2, y: y, width: d, height: d)
    let right = CGRect(x: midX + gap / 2 - d / 2, y: y, width: d, height: d)
    return (left, right)
}

private struct MarkRings: Shape {
    var separation: CGFloat
    var animatableData: CGFloat {
        get { separation }
        set { separation = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let (left, right) = markCircles(in: rect, separation: separation)
        var path = Path(ellipseIn: left)
        path.addEllipse(in: right)
        return path
    }
}

private struct MarkLens: Shape {
    var separation: CGFloat
    var animatableData: CGFloat {
        get { separation }
        set { separation = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let (left, right) = markCircles(in: rect, separation: separation)
        return Path(ellipseIn: left).intersection(Path(ellipseIn: right))
    }
}

/// A party's emoji on a rounded tile, like an icon in Settings.
struct EmojiTile: View {
    let emoji: String
    var size: CGFloat = 44

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.56))
            .frame(width: size, height: size)
            .background(
                Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// A party's cover on a rounded tile: its photo if it has one, otherwise its emoji.
struct PartyCover: View {
    let emoji: String
    let photoURL: URL?
    var size: CGFloat = 44

    var body: some View {
        if let photoURL {
            AsyncImage(url: photoURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
        } else {
            EmojiTile(emoji: emoji, size: size)
        }
    }
}

extension Date {
    /// When a party happens, in friendly terms: "Today at 8:00 PM", "Tomorrow at 6:00 PM",
    /// "Friday at 9:00 PM" within the week, otherwise "Sat, Oct 24 at 9:00 PM".
    var partyTimeText: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) { return "Today at \(time)" }
        if calendar.isDateInTomorrow(self) { return "Tomorrow at \(time)" }
        if calendar.isDateInYesterday(self) { return "Yesterday at \(time)" }

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: self)).day ?? 0
        if (2...6).contains(days) {
            return "\(formatted(.dateTime.weekday(.wide))) at \(time)"
        }
        let sameYear = calendar.isDate(self, equalTo: .now, toGranularity: .year)
        let day = sameYear
            ? formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : formatted(.dateTime.month(.abbreviated).day().year())
        return "\(day) at \(time)"
    }
}

/// "You're both going to Rooftop Sunset Session and Garage Disco."
/// Empty when there are no shared parties.
func bothGoingText(_ parties: [Party]) -> String? {
    guard !parties.isEmpty else { return nil }
    return "You're both going to \(parties.map(\.name).formatted(.list(type: .and)))."
}

/// Round profile photo with a system placeholder.
struct AvatarView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.secondarySystemFill)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// A button's content with an optional SF Symbol, centered as one unit.
/// (A full-width `Label` pins its icon to the left edge and throws the text off center.)
struct ButtonText: View {
    let title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One or more full-width buttons with a centered note underneath, used as a list row
/// with no background. Keeps the note evenly spaced from the buttons (list footers hug them).
struct ActionBlock<Buttons: View>: View {
    var note: String?
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 12) {
            buttons()
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
}

extension View {
    /// Liquid Glass button for the main action on a screen.
    func prominentActionStyle() -> some View {
        buttonStyle(.glassProminent)
            .controlSize(.large)
    }

    /// Liquid Glass button for a secondary action.
    func secondaryActionStyle() -> some View {
        buttonStyle(.glass)
            .controlSize(.large)
    }
}
