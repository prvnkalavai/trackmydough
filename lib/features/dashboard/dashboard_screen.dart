import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:syncfusion_flutter_charts/charts.dart'; // Keep for Sunburst
import 'package:sankey_flutter/sankey_flutter.dart'; // Import for new Sankey
import 'package:intl/intl.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Map<String, dynamic>> _sankeyLinksData = [];
  bool _isLoading = false;
  String? _errorMessage;
  String _selectedPeriod = "monthly";
  int _dateOffset = 0;
  double? _totalIncome;
  double? _totalExpenses;
  double? _savingsBuffer;

  // Doughnut chart specific state variables for category expenses
  List<Map<String, dynamic>>? _categoryExpenseData;
  double? _totalCategorizedExpensesFromCloud;
  bool _isCategoryExpenseLoading = false;
  String? _categoryExpenseErrorMessage;

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  @override
  void initState() {
    super.initState();
    _fetchSankeyData();
    _fetchCategoryExpenseData(); // Call to fetch category expense data
  }

  Future<void> _fetchSankeyData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final HttpsCallable callable = _functions.httpsCallable('getSankeyData');
      final HttpsCallableResult result = await callable.call(<String, dynamic>{
        'period': _selectedPeriod,
        'dateOffset': _dateOffset,
      });

      if (result.data != null && result.data['links'] != null) {
        final List<dynamic> linksData = result.data['links'];
        setState(() {
          _sankeyLinksData = linksData.map((link) => {
            'from': link['from'] as String,
            'to': link['to'] as String,
            'value': link['value'] as num,
          }).toList();
          _totalIncome = (result.data['totalIncome'] as num?)?.toDouble();
          _totalExpenses = (result.data['totalExpenses'] as num?)?.toDouble();
          _savingsBuffer = (result.data['savingsBuffer'] as num?)?.toDouble();
        });
      } else {
        setState(() {
          _sankeyLinksData = [];
          _totalIncome = null;
          _totalExpenses = null;
          _savingsBuffer = null;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _errorMessage = e.message ?? "An unknown error occurred.";
        _sankeyLinksData = [];
        _totalIncome = null;
        _totalExpenses = null;
        _savingsBuffer = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = "An unexpected error occurred: $e";
        _sankeyLinksData = [];
        _totalIncome = null;
        _totalExpenses = null;
        _savingsBuffer = null;
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
      final HttpsCallable callable = _functions.httpsCallable('getSunburstData'); // Backend function name remains getSunburstData
      final HttpsCallableResult result = await callable.call(<String, dynamic>{
        'period': _selectedPeriod,
        'dateOffset': _dateOffset,
      });

      if (result.data != null) {
        final Map<String, dynamic> responseData = result.data as Map<String, dynamic>;
        
        // Access 'categories' and 'totalCategorizedExpenses' directly from responseData
        final List<dynamic>? categoriesData = responseData['categories'] as List<dynamic>?;
        final num? totalExpensesNum = responseData['totalCategorizedExpenses'] as num?;

        if (categoriesData != null) {
          setState(() {
            _categoryExpenseData = categoriesData.map((item) => item as Map<String, dynamic>).toList();
            _totalCategorizedExpensesFromCloud = totalExpensesNum?.toDouble();
          });
        } else {
          // Handle cases where 'categories' is missing
          setState(() {
            _categoryExpenseData = null;
            _totalCategorizedExpensesFromCloud = null;
          });
        }
      } else {
        // Handle case where result.data is null
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
        title: const Text('Sankey Diagram'),
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
                        _dateOffset = 0; // Reset offset when changing period type
                      });
                      _fetchSankeyData();
                      _fetchCategoryExpenseData(); 
                      _fetchCategoryExpenseData();
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
                        _dateOffset = 0; // Reset offset
                      });
                      _fetchSankeyData();
                      _fetchSunburstData(); // Also fetch sunburst data
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
                        _dateOffset = 0; // YTD is always current year, offset 0
                      });
                      _fetchSankeyData();
                      _fetchSunburstData(); // Also fetch sunburst data
                    }
                  },
                ),
              ],
            ),
          ),
          // Optional: Add Previous/Next buttons here for monthly/yearly
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? Center(child: Text('Error: $_errorMessage'))
                    : _sankeyLinksData.isEmpty
                        ? const Center(child: Text('No data available for the selected period.'))
                        : Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: LayoutBuilder( // Use LayoutBuilder to get constraints for SankeyChart
                              builder: (context, constraints) {
                                // Data Transformation Logic
                                final Set<String> nodeNamesSet = {};
                                for (var link in _sankeyLinksData) {
                                  nodeNamesSet.add(link['from'] as String);
                                  nodeNamesSet.add(link['to'] as String);
                                }
                                final List<String> uniqueNodeNames = nodeNamesSet.toList();

                                final List<SankeyNodeInfo> nodes = uniqueNodeNames
                                    .map((name) => SankeyNodeInfo(label: name))
                                    .toList();

                                final List<SankeyLinkInfo> links = _sankeyLinksData.map((linkData) {
                                  final String fromNodeName = linkData['from'] as String;
                                  final String toNodeName = linkData['to'] as String;
                                  final double value = (linkData['value'] as num).toDouble();
                                  
                                  final int sourceId = uniqueNodeNames.indexOf(fromNodeName);
                                  final int targetId = uniqueNodeNames.indexOf(toNodeName);

                                  return SankeyLinkInfo(
                                    sourceId: sourceId,
                                    targetId: targetId,
                                    value: value,
                                  );
                                }).toList();

                                return SankeyChart(
                                  links: links,
                                  nodes: nodes,
                                  nodeWidth: 12.0, // Example styling
                                  nodeColor: Colors.blue.shade300, // Example styling
                                  linkColor: Colors.grey.shade300, // Example styling
                                  // labelStyle: TextStyle(fontSize: 10, color: Colors.black), // If available
                                  // showLabels: true, // If available for node labels
                                  height: constraints.maxHeight, 
                                  width: constraints.maxWidth,
                                );
                              }
                            ),
                          ),
          ),
          // Optional: Display summary figures
          if (_totalIncome != null && _totalExpenses != null && _savingsBuffer != null && !_isLoading && _errorMessage == null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text('Total Income: ${_totalIncome?.toStringAsFixed(2)}'),
                  Text('Total Expenses: ${_totalExpenses?.toStringAsFixed(2)}'),
                  Text('Savings/Buffer: ${_savingsBuffer?.toStringAsFixed(2)}'),
                ],
              ),
            ),
          // --- Sunburst Chart Section ---
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
                      // Text( // Title is now part of SfCircularChart
                      //   'Spending Breakdown ${(_sunburstTotalExpenses != null && _sunburstTotalExpenses! > 0) ? "- Total: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(_sunburstTotalExpenses)} " : ""}',
                      //   style: Theme.of(context).textTheme.titleLarge,
                      // ),
                      // const SizedBox(height: 8), // Adjust spacing if needed
                      SizedBox(
                        height: 350, // Keep or adjust height as needed
                        child: SfCircularChart(
                          title: ChartTitle(
                              text: 'Spending Breakdown ${(_totalCategorizedExpensesFromCloud != null && _totalCategorizedExpensesFromCloud! > 0) ? "\nTotal: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(_totalCategorizedExpensesFromCloud)}" : ""}',
                              textStyle: Theme.of(context).textTheme.titleMedium,
                              alignment: ChartAlignment.center
                          ),
                          legend: Legend(isVisible: true, overflowMode: LegendItemOverflowMode.wrap),
                          series: <CircularSeries<Map<String, dynamic>, String>>[
                            DoughnutSeries<Map<String, dynamic>, String>(
                              dataSource: _categoryExpenseData,
                              xValueMapper: (Map<String, dynamic> data, _) => data['name'] as String,
                              yValueMapper: (Map<String, dynamic> data, _) => data['value'] as num,
                              dataLabelSettings: DataLabelSettings(
                                isVisible: true,
                                labelPosition: CircularLabelPosition.outside,
                                labelIntersectAction: LabelIntersectAction.shift,
                                connectorLineSettings: const ConnectorLineSettings(type: ConnectorType.line, length: '10%'),
                                builder: (dynamic data, dynamic point, dynamic series, int pointIndex, int seriesIndex) {
                                  final num value = data['value'] as num;
                                  final String name = data['name'] as String;
                                  if (_totalCategorizedExpensesFromCloud != null && _totalCategorizedExpensesFromCloud! > 0 && value > 0) {
                                    final double percentage = (value / _totalCategorizedExpensesFromCloud!) * 100;
                                    if (percentage < 3) return null; // Hide label for very small segments
                                    return Text('${name}\n(${percentage.toStringAsFixed(1)}%)', style: const TextStyle(fontSize: 9, color: Colors.black87));
                                  }
                                  return Text(name, style: const TextStyle(fontSize: 9, color: Colors.black87)); // Fallback
                                }
                              ),
                              tooltipSettings: const TooltipSettings(enable: true, format: 'point.x: \$point.y'), // Updated format
                              innerRadius: '40%',
                              explode: true,
                              explodeIndex: 0, // Explode the first segment
                              palette: const <Color>[ // Example palette
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
