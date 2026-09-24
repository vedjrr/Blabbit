//! Word error rate for fixture evaluation. Normalisation: lowercase, strip
//! punctuation (apostrophes kept), split hyphens, and map single number words
//! ("three") to digits so "at three" and "at 3" compare equal.

pub fn normalize(text: &str) -> Vec<String> {
    let cleaned: String = text
        .to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '\'' { c } else { ' ' })
        .collect();
    cleaned
        .split_whitespace()
        .map(|w| w.trim_matches('\''))
        .filter(|w| !w.is_empty())
        .map(|w| number_word(w).map(str::to_string).unwrap_or_else(|| w.to_string()))
        .collect()
}

fn number_word(w: &str) -> Option<&'static str> {
    const WORDS: [&str; 21] = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty",
    ];
    const DIGITS: [&str; 21] = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16",
        "17", "18", "19", "20",
    ];
    WORDS.iter().position(|x| *x == w).map(|i| DIGITS[i])
}

/// Word-level edit counts between a reference and a hypothesis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WerCounts {
    pub substitutions: usize,
    pub deletions: usize,
    pub insertions: usize,
    pub reference_words: usize,
}

impl WerCounts {
    pub fn errors(&self) -> usize {
        self.substitutions + self.deletions + self.insertions
    }

    /// WER in [0, ∞). Empty reference: 0 if the hypothesis is empty too, else 1.
    pub fn wer(&self) -> f64 {
        if self.reference_words == 0 {
            return if self.insertions == 0 { 0.0 } else { 1.0 };
        }
        self.errors() as f64 / self.reference_words as f64
    }
}

pub fn wer_counts(reference: &str, hypothesis: &str) -> WerCounts {
    let r = normalize(reference);
    let h = normalize(hypothesis);
    // dp[i][j] = (cost, subs, dels, ins) aligning r[..i] with h[..j].
    let mut dp = vec![vec![(0usize, 0usize, 0usize, 0usize); h.len() + 1]; r.len() + 1];
    for i in 1..=r.len() {
        dp[i][0] = (i, 0, i, 0);
    }
    for j in 1..=h.len() {
        dp[0][j] = (j, 0, 0, j);
    }
    for i in 1..=r.len() {
        for j in 1..=h.len() {
            let diag = dp[i - 1][j - 1];
            let sub = if r[i - 1] == h[j - 1] { diag } else { (diag.0 + 1, diag.1 + 1, diag.2, diag.3) };
            let up = dp[i - 1][j];
            let del = (up.0 + 1, up.1, up.2 + 1, up.3);
            let left = dp[i][j - 1];
            let ins = (left.0 + 1, left.1, left.2, left.3 + 1);
            dp[i][j] = [sub, del, ins].into_iter().min_by_key(|c| c.0).unwrap_or(sub);
        }
    }
    let (_, substitutions, deletions, insertions) = dp[r.len()][h.len()];
    WerCounts { substitutions, deletions, insertions, reference_words: r.len() }
}

pub fn wer(reference: &str, hypothesis: &str) -> f64 {
    wer_counts(reference, hypothesis).wer()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_after_normalisation_is_zero() {
        assert_eq!(wer("Hello, World!", "hello world"), 0.0);
        assert_eq!(wer("Meet at three.", "meet at 3"), 0.0);
        assert_eq!(wer("state-of-the-art", "state of the art"), 0.0);
    }

    #[test]
    fn counts_each_edit_kind() {
        let sub = wer_counts("a b c d", "a x c d");
        assert_eq!((sub.substitutions, sub.deletions, sub.insertions), (1, 0, 0));
        let del = wer_counts("a b c d", "a c d");
        assert_eq!((del.substitutions, del.deletions, del.insertions), (0, 1, 0));
        let ins = wer_counts("a b c d", "a b c d e");
        assert_eq!((ins.substitutions, ins.deletions, ins.insertions), (0, 0, 1));
        let mixed = wer_counts("the cat sat on the mat", "the cat sit on mat now");
        assert_eq!(mixed.errors(), 3);
        assert!((mixed.wer() - 0.5).abs() < 1e-9);
    }

    #[test]
    fn empty_cases() {
        assert_eq!(wer("", ""), 0.0);
        assert_eq!(wer("", "noise"), 1.0);
        assert_eq!(wer("two words", ""), 1.0);
    }
}
