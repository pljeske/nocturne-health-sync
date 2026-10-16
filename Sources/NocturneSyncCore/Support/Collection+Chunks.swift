extension Collection {
  /// Consecutive slices of at most `size` elements, in order. The last slice may be shorter. An empty
  /// collection yields no slices.
  func chunks(ofCount size: Int) -> [SubSequence] {
    precondition(size > 0, "chunk size must be positive")
    var result: [SubSequence] = []
    var start = startIndex
    while start != endIndex {
      let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
      result.append(self[start..<end])
      start = end
    }
    return result
  }
}
