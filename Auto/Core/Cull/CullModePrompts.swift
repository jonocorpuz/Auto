import Foundation

/// The grading guide sent with every cull, whatever the mode: the model only describes
/// frames, and `CullPolicy` applies the mode. Pure text, no I/O.
nonisolated enum CullModePrompts {

    /// Run section for the first pass. Mode-neutral so it stays cached across runs.
    static let gradingGuide = """
        Grade every frame. You only describe frames; the app decides what to keep from your grades and the photographer's chosen strictness. Grade honestly: never raise a grade to save a frame or lower one to lose it.

        Step 1. Understand the frame before grading it: what is happening, who matters in it, and what part of the event's story it records.

        role, pick one:
        - milestone: a key moment of the event: an award or trophy handed over, the winners, a speech or presentation, opening or closing remarks, a performance, a ceremony.
        - group: people gathered or posed for the camera: a team, the winners, friends.
        - celebration: cheering, applause, hugging, laughing together, a strong positive reaction.
        - establishing: a wide view showing the venue, the crowd or the scale of the event.
        - candid: people doing something: talking, working, listening, networking.
        - detail: food, decor, signage, swag, products, hands, objects that set the scene.
        - crew: behind the scenes: another photographer or videographer, someone pointing a camera at the lens, gear, staff setting up.
        - accidental: the ground, ceiling or sky, a smear, lens cap, a misfire. Nothing was meant to be photographed. Grade it 1 everywhere and move on.

        Step 2. Grade 1 to 5 (1 very poor, 2 weak, 3 fine, 4 good, 5 excellent).
        - technical: is the intended subject in focus? Judge the subject, not the whole frame; a soft foreground person in front of a sharp subject is a composition problem, but focus landing on the wrong person is a technical one. Motion blur only counts when unintended. Exposure only counts when it cannot be recovered from RAW. 1 means unusable.
        - composition: depth (foreground elements, layers, an interesting background), deliberate framing, clean edges, sensible headspace, no large dead areas. A flat frame against a plain wall with nothing else in it is a 2. A busy room is context, not a flaw, when the subject still reads clearly. Feet or limbs cut off in a group or award shot cost one point at most.
        - subject: how the people who matter look. Smiling, laughing, engaged or attentive is good; bored, sad, blank or awkward is weak. Eyes closed, eating, yawning, mid-word grimace, scratching or picking is a 1. Scale-aware: only prominent faces count; a blink on a small face in a wide crowd shot does not. Use 0 when no person matters in the frame (a detail, an empty venue).
        - story: how much the frame matters to the event's story and how unique it is. A milestone, or the only frame of a key person or moment, is 5. A group shot of a team is 4. A lively candid with its own moment is 3 to 4. A generic snapshot, or one more frame of something already well covered in this group, is 1 to 2.

        Step 3. Moments. Label every frame with a moment within this group: "m1", "m2"… Frames share a label only when one would genuinely replace the other: same people, same pose and action, near-identical framing, a fraction of a second apart. A new pose, expression, gesture, framing (horizontal vs vertical, wide vs tight) or subject is a new moment. The app keeps only the best frame of each moment.

        Calibration: grade against professional event coverage. A typical frame is a 3 on every axis. Use the full range.
        """

    /// Run section for the Selects final round.
    static let finalRoundGuide = """
        What makes a select
        - Story first: milestones (awards, winners, speeches, opening and closing remarks), the group shots of each team, and real celebration carry the gallery. Do not drop them for prettier but generic frames.
        - Then moment and expression: a real laugh, a reaction, a gesture at its peak beat a posed or in-between frame.
        - Then composition: depth, foreground and background layers, an interesting background, the subject clearly separated.
        - Technical execution: the intended subject sharp, motion frozen or blurred on purpose.
        - Variety: the gallery should cover the whole event: different moments, people, angles and details.
        """
}
