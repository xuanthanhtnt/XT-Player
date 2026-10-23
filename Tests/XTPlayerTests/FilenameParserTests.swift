import XCTest

final class FilenameParserTests: XCTestCase {
    func testSceneMovieWithDolbyVisionAndAtmos() {
        let p = FilenameParser.parse("The.Matrix.1999.2160p.UHD.BluRay.REMUX.DV.HDR10.TrueHD.Atmos.7.1-FGT.mkv")
        XCTAssertEqual(p.title, "The Matrix")
        XCTAssertEqual(p.year, 1999)
        XCTAssertEqual(p.kind, .movie)
        XCTAssertEqual(p.resolution, "4K")
        XCTAssertEqual(p.dynamicRange, ["DV", "HDR10"])
        XCTAssertEqual(p.audio, ["TrueHD Atmos"])
        XCTAssertEqual(p.displayTitle, "The Matrix (1999)")
        XCTAssertEqual(p.badges, ["4K", "DV", "HDR10", "TrueHD Atmos"])
    }

    func testEpisodeWithStreamingTags() {
        let p = FilenameParser.parse("Severance.S02E05.Chikhai.Bardo.2160p.ATVP.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv")
        XCTAssertEqual(p.title, "Severance")
        XCTAssertEqual(p.kind, .episode(season: 2, episode: 5))
        XCTAssertNil(p.year)
        XCTAssertEqual(p.dynamicRange, ["DV", "HDR10"])
        XCTAssertEqual(p.audio, ["DD+ Atmos"])
        XCTAssertEqual(p.displayTitle, "Severance · S02E05")
    }

    func testPlexStyleMovieWithBracketTags() {
        let p = FilenameParser.parse("Dune Part Two (2024) [2160p HDR10+ DTS-HD MA 7.1].mkv")
        XCTAssertEqual(p.title, "Dune Part Two")
        XCTAssertEqual(p.year, 2024)
        XCTAssertEqual(p.resolution, "4K")
        XCTAssertEqual(p.dynamicRange, ["HDR10+"])
        XCTAssertEqual(p.audio, ["DTS-HD MA"])
    }

    func testTitleStartingWithAYearKeepsIt() {
        let p = FilenameParser.parse("2001.A.Space.Odyssey.1968.1080p.BluRay.x264.mkv")
        XCTAssertEqual(p.title, "2001 A Space Odyssey")
        XCTAssertEqual(p.year, 1968)
        XCTAssertEqual(p.resolution, "1080p")
        XCTAssertTrue(p.dynamicRange.isEmpty)
    }

    func testKodiStyleEpisodeWithGroupTag() {
        let p = FilenameParser.parse("[SubsPlease] Frieren - 1x05 (1080p).mkv")
        XCTAssertEqual(p.title, "Frieren")
        XCTAssertEqual(p.kind, .episode(season: 1, episode: 5))
    }

    func testEpisodeWithSpacedSeparators() {
        let p = FilenameParser.parse("Mr. Robot - S01E02 - eps1.1_ones-and-zer0es.mpeg")
        XCTAssertEqual(p.title, "Mr. Robot")
        XCTAssertEqual(p.kind, .episode(season: 1, episode: 2))
    }

    func testQualityTokenEndsTitleWhenThereIsNoYear() {
        let p = FilenameParser.parse("Some.Concert.Film.1080p.WEB-DL.AAC2.0.mp4")
        XCTAssertEqual(p.title, "Some Concert Film")
        XCTAssertNil(p.year)
        XCTAssertEqual(p.audio, ["AAC"])
    }

    func testPlainNameIsUntouched() {
        let p = FilenameParser.parse("Home Movie.mp4")
        XCTAssertEqual(p.title, "Home Movie")
        XCTAssertEqual(p.displayTitle, "Home Movie")
        XCTAssertTrue(p.badges.isEmpty)
    }

    func testFolderNamesParseAsTitleAndYear() {
        let p = FilenameParser.parse("Dune Part Two (2024)")
        XCTAssertEqual(p.title, "Dune Part Two")
        XCTAssertEqual(p.year, 2024)
    }

    func testSubtitleExtensionsAreKnown() {
        XCTAssertTrue(FilenameParser.subtitleExtensions.contains("ass"))
        XCTAssertFalse(FilenameParser.videoExtensions.contains("srt"))
    }
}
