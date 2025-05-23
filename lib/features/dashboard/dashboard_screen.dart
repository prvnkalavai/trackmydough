import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:syncfusion_flutter_charts/charts.dart'; // Keep for Doughnut
import 'package:intl/intl.dart';
import 'package:sankey_flutter/sankey_helpers.dart';
import 'package:sankey_flutter/sankey_link.dart';
import 'package:sankey_flutter/sankey_node.dart';
// SankeyDiagramWidget is available via sankey_helpers.dart or directly if exported

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Map<String, dynamic>> _sankeyLinksData = []; // Raw data from Firebase
  bool _isLoading = false;
  String? _errorMessage;
  String _selectedPeriod = "monthly";
  int _dateOffset = 0;
  double? _totalIncome;
  double? _totalExpenses;
  double? _savingsBuffer;

  // New Sankey specific state variables
  List<SankeyNode> _sankeyNodes = [];
  List<SankeyLink> _sankeyDiagramLinks = []; 
  Map<String, Color> _sankeyNodeColors = {};
  SankeyDataSet? _sankeyDataSet;
  int? _selectedSankeyNodeId; 

  // Doughnut chart specific state variables for category expenses
  List<Map<String, dynamic>>? _categoryExpenseData;
  double? _totalCategorizedExpensesFromCloud;
  bool _isCategoryExpenseLoading = false;
  String? _categoryExpenseErrorMessage;

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  @override
  void initState() {
    super.initState();
    // Fetch data with a default layout size.
    // The LayoutBuilder in build will trigger a re-layout with actual constraints if needed.
    _fetchSankeyData(); 
    _fetchCategoryExpenseData();
  }

  Future<void> _fetchSankeyData({Size layoutSize = const Size(600, 400)}) async { 
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      // Clear previous Sankey data for the new package
      _sankeyNodes = [];
      _sankeyDiagramLinks = [];
      _sankeyNodeColors = {};
      _sankeyDataSet = null;
      _selectedSankeyNodeId = null;
    });

    try {
      final HttpsCallable callable = _functions.httpsCallable('getSankeyData');
      final HttpsCallableResult result = await callable.call(<String, dynamic>{
        'period': _selectedPeriod,
        'dateOffset': _dateOffset,
      });

      if (result.data != null && result.data['links'] != null) {
        final List<dynamic> linksRawData = result.data['links'];
        // Store the raw data in _sankeyLinksData
        final List<Map<String, dynamic>> newSankeyLinksData = linksRawData.map((link) => {
          'from': link['from'] as String,
          'to': link['to'] as String,
          'value': link['value'] as num,
        }).toList();

        // a. Create unique nodes and map them
        final Map<String, SankeyNode> nodeMap = {};
        int nodeIdCounter = 0;
        for (var linkData in newSankeyLinksData) {
          final String from = linkData['from'] as String;
          final String to = linkData['to'] as String;
          if (!nodeMap.containsKey(from)) {
            nodeMap[from] = SankeyNode(id: nodeIdCounter++, label: from);
          }
          if (!nodeMap.containsKey(to)) {
            nodeMap[to] = SankeyNode(id: nodeIdCounter++, label: to);
          }
        }
        final List<SankeyNode> newNodes = nodeMap.values.toList();

        // b. Create SankeyLinks using the SankeyNode objects
        final List<SankeyLink> newLinks = newSankeyLinksData.map((linkData) {
          final SankeyNode sourceNode = nodeMap[linkData['from'] as String]!;
          final SankeyNode targetNode = nodeMap[linkData['to'] as String]!;
          final double value = (linkData['value'] as num).toDouble();
          // Ensure value is positive for sankey_flutter package
          return SankeyLink(source: sourceNode, target: targetNode, value: value.abs());
        }).toList();

        // c. Generate node colors
        final Map<String, Color> newNodeColors = generateDefaultNodeColorMap(newNodes);

        // d. Create SankeyDataSet
        final SankeyDataSet newDataSet = SankeyDataSet(nodes: newNodes, links: newLinks);

        // e. Calculate layout using the provided or default layoutSize
        final sankeyLayout = generateSankeyLayout(
          width: layoutSize.width, 
          height: layoutSize.height, 
          nodeWidth: 15, 
          nodePadding: 10, 
        );
        newDataSet.layout(sankeyLayout);

        setState(() {
          _sankeyLinksData = newSankeyLinksData; 
          _totalIncome = (result.data['totalIncome'] as num?)?.toDouble();
          _totalExpenses = (result.data['totalExpenses'] as num?)?.toDouble();
          _savingsBuffer = (result.data['savingsBuffer'] as num?)?.toDouble();
          
          _sankeyNodes = newNodes;
          _sankeyDiagramLinks = newLinks; 
          _sankeyNodeColors = newNodeColors;
          _sankeyDataSet = newDataSet;
          _errorMessage = null; 
        });
      } else {
        setState(() {
          _sankeyLinksData = []; 
          _totalIncome = null;
          _totalExpenses = null;
          _savingsBuffer = null;
          _sankeyDataSet = null; 
          _errorMessage = "No data received from the server.";
        });
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _errorMessage = e.message ?? "An unknown error occurred.";
        _sankeyLinksData = [];
        _totalIncome = null;
        _totalExpenses = null;
        _savingsBuffer = null;
        _sankeyDataSet = null; 
      });
    } catch (e) {
      setState(() {
        _errorMessage = "An unexpected error occurred: $e";
        _sankeyLinksData = [];
        _totalIncome = null;
        _totalExpenses = null;
        _savingsBuffer = null;
        _sankeyDataSet = null; 
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchCategoryExpenseData() async {
    setState(() {
      _isCategoryExpenseLoading = true;
      _categoryExpenseErrorMessage = null;
    });

    try {
      final HttpsCallable callable = _functions.httpsCallable('getSunburstData');
      final HttpsCallableResult result = await callable.call(<String, dynamic>{
        'period': _selectedPeriod,
        'dateOffset': _dateOffset,
      });

      if (result.data != null) {
        final Map<String, dynamic> responseData = result.data as Map<String, dynamic>;
        
        final List<dynamic>? categoriesData = responseData['categories'] as List<dynamic>?;
        final num? totalExpensesNum = responseData['totalCategorizedExpenses'] as num?;

        if (categoriesData != null) {
          setState(() {
            _categoryExpenseData = categoriesData.map((item) => item as Map<String, dynamic>).toList();
            _totalCategorizedExpensesFromCloud = totalExpensesNum?.toDouble();
          });
        } else {
          setState(() {
            _categoryExpenseData = null;
            _totalCategorizedExpensesFromCloud = null;
          });
        }
      } else {
        setState(() {
          _categoryExpenseData = null;
          _totalCategorizedExpensesFromCloud = null;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _categoryExpenseErrorMessage = e.message ?? "An unknown error occurred while fetching category expense data.";
        _categoryExpenseData = null;
        _totalCategorizedExpensesFromCloud = null;
      });
    } catch (e) {
      setState(() {
        _categoryExpenseErrorMessage = "An unexpected error occurred: $e";
        _categoryExpenseData = null;
        _totalCategorizedExpensesFromCloud = null;
      });
    } finally {
      setState(() {
        _isCategoryExpenseLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Financial Dashboard'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('Monthly'),
                  selected: _selectedPeriod == 'monthly',
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedPeriod = 'monthly';
                        _dateOffset = 0; 
                      });
                      _fetchSankeyData(); 
                      _fetchCategoryExpenseData();
                    }
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Yearly'),
                  selected: _selectedPeriod == 'yearly',
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedPeriod = 'yearly';
                        _dateOffset = 0; 
                      });
                      _fetchSankeyData();
                      _fetchCategoryExpenseData();
                    }
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('YTD'),
                  selected: _selectedPeriod == 'yearToDate',
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedPeriod = 'yearToDate';
                        _dateOffset = 0; 
                      });
                      _fetchSankeyData();
                      _fetchCategoryExpenseData();
                    }
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? Center(child: Text('Error: $_errorMessage'))
                    : (_sankeyDataSet == null || _sankeyDataSet!.nodes.isEmpty) 
                        ? const Center(child: Text('No data available for the selected period.'))
                        : Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                // Re-calculate layout with actual constraints if dataset exists
                                if (_sankeyDataSet != null && _sankeyDataSet!.nodes.isNotEmpty) {
                                  final sankeyLayout = generateSankeyLayout(
                                    width: constraints.maxWidth,
                                    height: constraints.maxHeight,
                                    nodeWidth: 15, 
                                    nodePadding: 10, 
                                  );
                                  _sankeyDataSet!.layout(sankeyLayout); // Update layout on existing dataset

                                  return SizedBox( 
                                    height: constraints.maxHeight,
                                    width: constraints.maxWidth,
                                    child: SankeyDiagramWidget(
                                      data: _sankeyDataSet!,
                                      nodeColors: _sankeyNodeColors,
                                      selectedNodeId: _selectedSankeyNodeId,
                                      onNodeTap: (int? nodeId) {
                                        setState(() {
                                          _selectedSankeyNodeId = nodeId;
                                        });
                                      },
                                      size: Size(constraints.maxWidth, constraints.maxHeight),
                                      showLabels: true,
                                    ),
                                  );
                                } 
                                return const Center(child: Text('Preparing Sankey data...'));
                              }
                            ),
                          ),
          ),
          if (_totalIncome != null && _totalExpenses != null && _savingsBuffer != null && !_isLoading && _errorMessage == null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Text('Income: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(_totalIncome)}'),
                  Text('Expenses: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(_totalExpenses)}'),
                  Text('Buffer: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(_savingsBuffer)}'),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isCategoryExpenseLoading)
                  const Center(child: CircularProgressIndicator())
                else if (_categoryExpenseErrorMessage != null)
                  Center(child: Text('Category Expense Error: $_categoryExpenseErrorMessage'))
                else if (_categoryExpenseData != null && _categoryExpenseData!.isNotEmpty)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 300, 
                        child: SfCircularChart(
                          title: ChartTitle(
                              text: 'Spending Breakdown ${(_totalCategorizedExpensesFromCloud != null && _totalCategorizedExpensesFromCloud! > 0) ? "\nTotal: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(_totalCategorizedExpensesFromCloud)}" : ""}',
                              textStyle: Theme.of(context).textTheme.titleMedium,
                              alignment: ChartAlignment.center
                          ),
                          legend: Legend(isVisible: true, overflowMode: LegendItemOverflowMode.wrap, position: LegendPosition.bottom),
                          series: <CircularSeries<Map<String, dynamic>, String>>[
                            DoughnutSeries<Map<String, dynamic>, String>(
                              dataSource: _categoryExpenseData,
                              xValueMapper: (Map<String, dynamic> data, _) => data['name'] as String,
                              yValueMapper: (Map<String, dynamic> data, _) => data['value'] as num,
                              dataLabelSettings: DataLabelSettings(
                                isVisible: true,
                                labelPosition: CircularLabelPosition.outside,
                                labelIntersectAction: LabelIntersectAction.shift,
                                connectorLineSettings: const ConnectorLineSettings(type: ConnectorType.line, length: '8%'),
                                builder: (dynamic data, dynamic point, dynamic series, int pointIndex, int seriesIndex) {
                                  final num value = data['value'] as num;
                                  final String name = data['name'] as String;
                                  if (_totalCategorizedExpensesFromCloud != null && _totalCategorizedExpensesFromCloud! > 0 && value > 0) {
                                    final double percentage = (value / _totalCategorizedExpensesFromCloud!) * 100;
                                    if (percentage < 3) return null; 
                                    return Text('${name} (${percentage.toStringAsFixed(1)}%)', style: const TextStyle(fontSize: 8, color: Colors.black87)); 
                                  }
                                  return Text(name, style: const TextStyle(fontSize: 8, color: Colors.black87));
                                }
                              ),
                              tooltipSettings: const TooltipSettings(enable: true, format: 'point.x: \$point.y'),
                              innerRadius: '40%',
                              explode: true,
                              explodeIndex: 0, 
                              palette: const <Color>[ 
                                Colors.blue, Colors.green, Colors.orange, Colors.red, Colors.purple,
                                Colors.brown, Colors.pink, Colors.teal, Colors.indigo, Colors.cyan,
                                Colors.lime, Colors.amber,
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                else
                  const Center(child: Text('No spending data for Doughnut chart for the selected period.')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
