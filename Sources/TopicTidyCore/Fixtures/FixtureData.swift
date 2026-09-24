// Generated from Resources/fixtures/*.json. See TopicTidyCoreTests for the
// equality test that keeps these embedded copies in sync with the JSON files.
import Foundation

public enum FixtureData {
    public enum Name: String {
        case core = "benchmark_core"
        case holdout = "holdout_unseen"
        case upgradeDevelopment = "upgrade_development"
        case upgradeHoldout = "upgrade_holdout"
    }

    public static func json(for name: Name) -> String {
        switch name {
        case .core: return core
        case .holdout: return holdout
        case .upgradeDevelopment: return upgradeDevelopment
        case .upgradeHoldout: return upgradeHoldout
        }
    }

    static let core = #"""
{
  "name": "TopicTidy core quality benchmark",
  "documents": [
    {"name": "ELEC6008 Lecture 01.md", "content": "Power electronics converters and grid control."},
    {"name": "ELEC6008 Lecture 02.md", "content": "Power electronics inverters and grid control."},

    {"name": "01 Systems Overview.md", "content": "ELEC6200 ELEC6200 autonomous control systems architecture."},
    {"name": "02 Control Design.md", "content": "ELEC6200 ELEC6200 autonomous control systems design."},

    {"name": "ELEC6103 Project Overview.md", "content": "Embedded systems project requirements."},
    {"name": "ELEC6103 Project Plan.md", "content": "Embedded systems project schedule."},
    {"name": "ELEC6104 Project Overview.md", "content": "Power systems project requirements."},
    {"name": "ELEC6104 Project Plan.md", "content": "Power systems project schedule."},

    {"name": "Grid Storage Design v1.pdf", "title": "Grid Storage Design", "content": "Battery grid storage design capacity safety architecture.", "vector": [0.0, 1.0, 0.0]},
    {"name": "Grid Storage Design v2.docx", "title": "Grid Storage Design Revised", "content": "Battery grid storage design capacity safety architecture revised.", "vector": [0.0, 1.0, 0.0]},

    {"name": "Large Renewable Systems Report.pdf", "title": "Renewable Systems Report", "content": "Renewable systems modelling solar wind storage performance.", "vector": [0.0, 0.0, 1.0]},
    {"name": "Renewable Systems Appendix.md", "title": "Renewable Systems Appendix", "content": "Renewable systems modelling solar wind storage appendix.", "vector": [0.0, 0.0, 1.0]},

    {"name": "电池储能概论.md", "title": "电池储能概论", "content": "电池储能系统的容量、安全与电网调度。", "native_space": "zh-Hans", "pivot_vector": [0.6, 0.8, 0.0], "translated_content": "Battery storage systems capacity safety and grid dispatch."},
    {"name": "Reference Notes.md", "title": "Reference Notes", "content": "Battery storage systems capacity safety and grid operations.", "native_space": "en", "pivot_vector": [0.6, 0.8, 0.0]},

    {"name": "cs229-notes1.md", "title": "CS229 Linear Models", "content": "Linear regression likelihood and optimization.", "vector": [0.7, 0.7, 0.0]},
    {"name": "cs229-deep-learning.md", "title": "CS229 Deep Learning", "content": "Neural network backpropagation and representation learning.", "vector": [0.7, 0.7, 0.0]},

    {"name": "01-memory.md", "title": "FreeRTOS Memory Management", "content": "Heap allocation and task stacks.", "vector": [0.8, 0.6, 0.0]},
    {"name": "02-queues.md", "title": "FreeRTOS Queues", "content": "Queue messages between concurrent tasks.", "vector": [0.8, 0.6, 0.0]},
    {"name": "03-timers.md", "title": "FreeRTOS Software Timers", "content": "Timer callbacks and scheduler behavior.", "vector": [0.8, 0.6, 0.0]},

    {"name": "README.md", "title": "Embedded Linux Notes", "content": "# Embedded Linux Notes\n[Processes](01-processes.md)\n[Files](02-files.md)\n[Signals](03-signals.md)"},
    {"name": "01-processes.md", "content": "fork exec process lifecycle"},
    {"name": "02-files.md", "content": "open read write file descriptors"},
    {"name": "03-signals.md", "content": "sigaction interrupt handling"},

    {"name": "tax receipt.md", "content": "Annual personal tax receipt and payment.", "source_urls": ["https://portal.example.edu/download/item"]},
    {"name": "hotel booking.md", "content": "Hotel reservation itinerary and booking.", "source_urls": ["https://portal.example.edu/download/item"]},
    {"name": "citation-noise.md", "content": "HAVE1000 TASK1000 NOTES2021 ORNL2005 are citation and prose artifacts, not course codes."},
    {"name": "random.json", "content": "{\"unrelated\": true}"},
    {"name": "installer.dmg", "content": ""},
    {"name": "archive.zip", "content": ""}
  ],
  "expected_clusters": {
    "ELEC6008": ["ELEC6008 Lecture 01.md", "ELEC6008 Lecture 02.md"],
    "ELEC6200": ["01 Systems Overview.md", "02 Control Design.md"],
    "ELEC6103": ["ELEC6103 Project Overview.md", "ELEC6103 Project Plan.md"],
    "ELEC6104": ["ELEC6104 Project Overview.md", "ELEC6104 Project Plan.md"],
    "Grid Storage": ["Grid Storage Design v1.pdf", "Grid Storage Design v2.docx"],
    "Renewable Systems": ["Large Renewable Systems Report.pdf", "Renewable Systems Appendix.md"],
    "Cross-language Storage": ["电池储能概论.md", "Reference Notes.md"],
    "CS229": ["cs229-notes1.md", "cs229-deep-learning.md"],
    "FreeRTOS": ["01-memory.md", "02-queues.md", "03-timers.md"],
    "Embedded Linux Notes": ["README.md", "01-processes.md", "02-files.md", "03-signals.md"]
  },
  "expected_unclassified": [
    "archive.zip",
    "citation-noise.md",
    "hotel booking.md",
    "installer.dmg",
    "random.json",
    "tax receipt.md"
  ]
}

"""#

    static let holdout = #"""
{
  "name": "TopicTidy unseen safety holdout",
  "documents": [
    {"name": "COMP4101 Lecture 01 Graph Search.md", "content": "Graph search frontiers, breadth first search and path cost."},
    {"name": "COMP4101 Lecture 02 Heuristics.md", "content": "Heuristic search, admissibility and A star evaluation."},
    {"name": "01 Assignment Brief.md", "title": "COMP4101 Assignment Brief", "content": "COMP4101 COMP4101 implement a route planning search agent."},

    {"name": "COMP4102 Lecture 01 Graph Search.md", "content": "Graph search frontiers, breadth first search and path cost."},
    {"name": "COMP4102 Lecture 02 Heuristics.md", "content": "Heuristic search, admissibility and A star evaluation."},
    {"name": "02 Assignment Brief.md", "title": "COMP4102 Assignment Brief", "content": "COMP4102 COMP4102 implement a route planning search agent."},

    {"name": "README-Atlas42.md", "title": "Atlas42 Project Index", "content": "# Atlas42 Project Index\n[Design](Atlas42-design.md)\n[Tests](Atlas42-tests.md)\n[Release](Atlas42-release.md)"},
    {"name": "Atlas42-design.md", "title": "Atlas42 Mechanical Design", "content": "Enclosure tolerances, fasteners and weather sealing."},
    {"name": "Atlas42-tests.md", "title": "Atlas42 Validation Tests", "content": "Ingress testing, vibration protocol and acceptance limits."},
    {"name": "Atlas42-release.md", "title": "Atlas42 Release Checklist", "content": "Manufacturing handoff, packaging and shipping approval."},

    {"name": "Harbor Sensor Field Report v1.pdf", "title": "Harbor Sensor Field Report", "content": "Coastal salinity sensor calibration enclosure and field deployment.", "vector": [0.0, 1.0, 0.0, 0.0]},
    {"name": "Harbor Sensor Field Report revised.docx", "title": "Harbor Sensor Field Report Revised", "content": "Coastal salinity sensor calibration enclosure and revised field deployment.", "vector": [0.0, 1.0, 0.0, 0.0]},

    {"name": "Battery Storage Safety.md", "title": "Battery Storage Safety", "content": "Battery storage thermal safety monitoring and emergency isolation.", "native_space": "en", "pivot_vector": [0.6, 0.8, 0.0, 0.0]},
    {"name": "电池储能安全指南.md", "title": "电池储能安全指南", "content": "电池储能系统的热安全监测、消防和紧急隔离。", "native_space": "zh-Hans", "pivot_vector": [0.6, 0.8, 0.0, 0.0], "translated_content": "Battery storage thermal safety monitoring fire protection and emergency isolation."},

    {"name": "index.md", "title": "Personal Reference Index", "content": "# Personal Reference Index\n[Budget](budget.md)\n[Travel](travel.md)\n[Recipe](recipe.md)"},
    {"name": "budget.md", "content": "monthly household spending and utility totals"},
    {"name": "travel.md", "content": "train reservations and museum opening times"},
    {"name": "recipe.md", "content": "sourdough starter feeding and oven temperature"},

    {"name": "ECON5001 Project Overview.md", "content": "Panel data estimation and labour market outcomes."},
    {"name": "ECON5001 Project Results.md", "content": "Panel data estimates and labour market robustness checks."},
    {"name": "ECON5002 Project Overview.md", "content": "Panel data estimation and labour market outcomes."},
    {"name": "ECON5002 Project Results.md", "content": "Panel data estimates and labour market robustness checks."},

    {"name": "Sensor Field Guide.md", "content": "Telemetry probe calibration and sampling units.", "vector": [0.9, 0.1, 0.0, 0.0], "source_urls": ["https://raw.githubusercontent.com/example/sensor-course/main/lessons/README.md"]},
    {"name": "Device Provisioning.md", "content": "Device identity enrollment and gateway setup.", "vector": [0.9, 0.1, 0.0, 0.0], "source_urls": ["https://raw.githubusercontent.com/example/sensor-course/main/setup/README.md"]},
    {"name": "Transit Brief.md", "content": "Rail timetable planning and passenger connections.", "vector": [0.9, 0.1, 0.0, 0.0], "source_urls": ["https://raw.githubusercontent.com/example/transit-course/main/lessons/README.md"]},
    {"name": "Kitchen Brief.md", "content": "Oven preparation and seasonal meal service.", "vector": [0.9, 0.1, 0.0, 0.0], "source_urls": ["https://raw.githubusercontent.com/example/kitchen-course/main/lessons/README.md"]},
    {"name": "Workshop Equipment.md", "content": "Metal cutting machine maintenance and workshop inventory.", "native_space": "en", "pivot_vector": [1.0, 0.0, 0.0, 0.0]},
    {"name": "烘焙配方.md", "content": "面包烘焙配方与烤箱温度记录。", "native_space": "zh-Hans", "pivot_vector": [0.89, 0.4559605, 0.0, 0.0], "translated_content": "Bread baking recipe and oven temperature records."},

    {"name": "report.md", "content": "annual personal tax filing receipt"},
    {"name": "final-report-energy.md", "content": "solar inverter efficiency and power quality measurements"},
    {"name": "project.md", "content": "community theatre volunteer schedule"},
    {"name": "project-ocean-cleanup.md", "content": "coastal waste collection logistics"},
    {"name": "notes.md", "content": "dentist appointment and prescription reminder"},
    {"name": "notes-bayesian-statistics.md", "content": "posterior distributions and prior predictive checks"},

    {"name": "tax-statement.pdf", "content": "income tax statement and withholding", "source_urls": ["https://portal.example.edu/download/item/100"]},
    {"name": "dorm-booking.pdf", "content": "student residence room booking", "source_urls": ["https://portal.example.edu/download/item/200"]},
    {"name": "cafeteria-menu.pdf", "content": "weekly lunch menu and allergens", "source_urls": ["https://portal.example.edu/download/item/300"]},

    {"name": "AlphaGrid solar forecast.md", "content": "solar irradiance forecast for an urban distribution grid"},
    {"name": "BetaFarm solar forecast.md", "content": "solar irradiance forecast for an agricultural microgrid"},

    {"name": "random.json", "content": "{\"theme\": \"dark\", \"enabled\": true}"},
    {"name": "installer.dmg", "content": ""},
    {"name": "archive.zip", "content": ""},
    {"name": "IMG_2048.jpg", "content": ""},
    {"name": "boarding-pass.pdf", "content": "flight boarding pass seat and gate"},
    {"name": "resume.docx", "content": "employment history and professional skills"},
    {"name": "invoice.pdf", "content": "equipment purchase invoice and payment due"},
    {"name": "cooking-recipes.md", "content": "pasta sauce vegetables and baking instructions"},
    {"name": "meeting-minutes.md", "content": "neighbourhood committee meeting actions"}
  ],
  "expected_clusters": {
    "COMP4101": ["COMP4101 Lecture 01 Graph Search.md", "COMP4101 Lecture 02 Heuristics.md", "01 Assignment Brief.md"],
    "COMP4102": ["COMP4102 Lecture 01 Graph Search.md", "COMP4102 Lecture 02 Heuristics.md", "02 Assignment Brief.md"],
    "Atlas42": ["README-Atlas42.md", "Atlas42-design.md", "Atlas42-tests.md", "Atlas42-release.md"],
    "Harbor Sensor": ["Harbor Sensor Field Report v1.pdf", "Harbor Sensor Field Report revised.docx"],
    "Cross-language Battery Safety": ["Battery Storage Safety.md", "电池储能安全指南.md"],
    "Personal Reference Index": ["index.md", "budget.md", "travel.md", "recipe.md"],
    "ECON5001": ["ECON5001 Project Overview.md", "ECON5001 Project Results.md"],
    "ECON5002": ["ECON5002 Project Overview.md", "ECON5002 Project Results.md"],
    "Sensor Course": ["Sensor Field Guide.md", "Device Provisioning.md"]
  },
  "expected_unclassified": [
    "report.md",
    "Transit Brief.md",
    "Kitchen Brief.md",
    "Workshop Equipment.md",
    "烘焙配方.md",
    "final-report-energy.md",
    "project.md",
    "project-ocean-cleanup.md",
    "notes.md",
    "notes-bayesian-statistics.md",
    "tax-statement.pdf",
    "dorm-booking.pdf",
    "cafeteria-menu.pdf",
    "AlphaGrid solar forecast.md",
    "BetaFarm solar forecast.md",
    "random.json",
    "installer.dmg",
    "archive.zip",
    "IMG_2048.jpg",
    "boarding-pass.pdf",
    "resume.docx",
    "invoice.pdf",
    "cooking-recipes.md",
    "meeting-minutes.md"
  ]
}

"""#

    static let upgradeDevelopment = #"""
{
  "name": "TopicTidy upgrade development",
  "documents": [
    {"name":"Atlas Research Design.md","content":"ELEC7301 ELEC7301 atlas research sensor calibration harbor measurement methods.","vector":[1,0,0],"source_urls":["https://github.com/acme/atlas/blob/main/research/design.md"]},
    {"name":"Harbor Research Field.md","content":"ELEC7301 ELEC7301 harbor research sensor calibration field measurements.","vector":[0.9,0.43589,0],"source_urls":["https://github.com/acme/atlas/blob/main/research/field.md"]},
    {"name":"Atlas Research Addendum.md","content":"atlas research sensor calibration harbor measurement methods field notes.","vector":[1,0,0],"source_urls":["https://github.com/acme/atlas/blob/main/research/design-addendum.md"]},

    {"name":"Solar Grid Training One.md","content":"solar grid inverter design controls training module and experiments","vector":[1,0,0],"native_views":{"identity":[1,0],"overview":[1,0],"body":[0,1]}},
    {"name":"Grid Solar Tutorial Two.md","content":"solar grid inverter design controls tutorial module and exercises","vector":[0,1,0],"native_views":{"identity":[1,0],"overview":[1,0],"body":[1,0]}},

    {"name":"电池热安全讲义.md","title":"电池热安全讲义","content":"电池储能的热监测、隔离和消防程序。","native_space":"zh-Hans","pivot_vector":[1,0],"pivot_views":{"identity":[1,0],"overview":[1,0],"body":[0,1]},"translated_content":"Battery storage thermal monitoring isolation and fire safety."},
    {"name":"Battery Safety Brief.md","content":"Battery storage thermal monitoring isolation and fire safety.","native_space":"en","pivot_vector":[0,1],"pivot_views":{"identity":[1,0],"overview":[1,0],"body":[1,0]}},

    {"name":"ELEC7302 Research Design.md","content":"ELEC7302 ELEC7302 atlas research sensor calibration harbor measurement methods.","vector":[1,0,0]},
    {"name":"ELEC7302 Research Field.md","content":"ELEC7302 ELEC7302 harbor research sensor calibration field measurements.","vector":[1,0,0]},
    {"name":"tax invoice.md","content":"Annual household tax invoice for travel expenses.","source_urls":["https://github.com/acme/atlas/blob/main/research/tax.md"]},
    {"name":"oven recipe.md","content":"Baking bread dough with oven temperature records.","source_urls":["https://github.com/acme/other/blob/main/research/recipe.md"]},

    {"name":"Origin Graph Lesson.md","content":"vertex edge traversal adjacency path","vector":[0,1,0],"native_views":{"identity":[1,0],"overview":[1,0],"body":[1,0]},"source_urls":["https://github.com/example/course/blob/main/graph/lesson.md"]},
    {"name":"Origin Graph Practice.md","content":"breadth first depth first spanning trees","vector":[0,1,0],"native_views":{"identity":[1,0],"overview":[1,0],"body":[1,0]},"source_urls":["https://github.com/example/course/blob/main/graph/practice.md"]},
    {"name":"Origin Logic Lesson.md","content":"symbolic rules inference proof calculus","vector":[0,1,0],"native_views":{"identity":[0,1],"overview":[0.72,0.693974],"body":[0.8,0.6]},"source_urls":["https://github.com/example/course/blob/main/logic/lesson.md"]},
    {"name":"Origin Logic Practice.md","content":"predicate reasoning theorem derivation","vector":[0,1,0],"native_views":{"identity":[0,1],"overview":[0.72,0.693974],"body":[0.8,0.6]},"source_urls":["https://github.com/example/course/blob/main/logic/practice.md"]},
    {"name":"Origin Holiday.md","content":"Vacation hotel booking itinerary","source_urls":["https://github.com/example/course/blob/main/travel/holiday.md"]},

    {"name":"MIT6.006S20 Lec 1.md","content":"MIT algorithms graphs sorting dynamic programming","vector":[0,0,1],"source_urls":["https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/lec1.pdf"]},
    {"name":"MIT6.006S20 Lec 2.md","content":"MIT algorithms graphs sorting dynamic programming","vector":[0,0,1],"source_urls":["https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/lec2.pdf"]},
    {"name":"MIT6.046JS15 Lec 1.md","content":"MIT algorithms graphs sorting dynamic programming","vector":[0,0,1],"source_urls":["https://ocw.mit.edu/courses/6-046j-design-and-analysis-of-algorithms-spring-2015/lec1.pdf"]},
    {"name":"MIT6.046JS15 Lec 2.md","content":"MIT algorithms graphs sorting dynamic programming","vector":[0,0,1],"source_urls":["https://ocw.mit.edu/courses/6-046j-design-and-analysis-of-algorithms-spring-2015/lec2.pdf"]}
  ],
  "expected_clusters": {
    "ELEC7301": ["Atlas Research Design.md","Harbor Research Field.md","Atlas Research Addendum.md"],
    "Multi-view Solar": ["Solar Grid Training One.md","Grid Solar Tutorial Two.md"],
    "Multi-view Battery": ["电池热安全讲义.md","Battery Safety Brief.md"],
    "ELEC7302": ["ELEC7302 Research Design.md","ELEC7302 Research Field.md"],
    "Source Anchored Chapters": ["Origin Graph Lesson.md","Origin Graph Practice.md","Origin Logic Lesson.md","Origin Logic Practice.md"],
    "MIT 6.006": ["MIT6.006S20 Lec 1.md","MIT6.006S20 Lec 2.md"],
    "MIT 6.046J": ["MIT6.046JS15 Lec 1.md","MIT6.046JS15 Lec 2.md"]
  },
  "expected_unclassified": ["tax invoice.md","oven recipe.md","Origin Holiday.md"]
}

"""#

    static let upgradeHoldout = #"""
{
  "name": "TopicTidy upgrade independent holdout",
  "documents": [
    {"name":"Delta Research Prototype.md","content":"COMP7303 COMP7303 delta research coastal telemetry sensor calibration methods.","vector":[1,0,0],"source_urls":["https://github.com/lab/delta/blob/main/notes/prototype.md"]},
    {"name":"Coastal Research Validation.md","content":"COMP7303 COMP7303 coastal research telemetry sensor validation field methods.","vector":[0.9,0.43589,0],"source_urls":["https://github.com/lab/delta/blob/main/notes/validation.md"]},
    {"name":"Delta Research Supplement.md","content":"delta research coastal telemetry sensor calibration methods field supplement.","vector":[1,0,0],"source_urls":["https://github.com/lab/delta/blob/main/notes/prototype-supplement.md"]},

    {"name":"Harbor Power Notes.md","content":"harbor power inverter protection circuit testing exercise","vector":[1,0,0],"native_views":{"identity":[1,0],"overview":[1,0],"body":[0,1]}},
    {"name":"Power Harbor Exercises.md","content":"harbor power inverter protection circuit practice exercise","vector":[0,1,0],"native_views":{"identity":[1,0],"overview":[1,0],"body":[1,0]}},

    {"name":"Transit Platform Guide.md","content":"Train platform crowd routing and timetable planning.","native_space":"en","pivot_vector":[1,0],"pivot_views":{"identity":[1,0],"overview":[0,1],"body":[0,1]}},
    {"name":"烘焙配方手册.md","content":"烤箱烘焙配方与发酵时间记录。","native_space":"zh-Hans","pivot_vector":[0.9,0.43589],"pivot_views":{"identity":[1,0],"overview":[1,0],"body":[1,0]},"translated_content":"Baking recipes oven temperature and fermentation timing."},
    {"name":"Delta Other Course.md","content":"COMP7304 COMP7304 delta research coastal telemetry sensor calibration methods.","vector":[1,0,0]},
    {"name":"Delta Other Lab.md","content":"COMP7304 COMP7304 coastal telemetry sensor field measurements.","vector":[1,0,0]},
    {"name":"holiday booking.md","content":"Hotel booking and vacation itinerary.","source_urls":["https://github.com/lab/delta/blob/main/notes/holiday.md"]}
  ],
  "expected_clusters": {
    "COMP7303": ["Delta Research Prototype.md","Coastal Research Validation.md","Delta Research Supplement.md"],
    "Harbor Power": ["Harbor Power Notes.md","Power Harbor Exercises.md"],
    "COMP7304": ["Delta Other Course.md","Delta Other Lab.md"]
  },
  "expected_unclassified": ["Transit Platform Guide.md","烘焙配方手册.md","holiday booking.md"]
}

"""#


}
