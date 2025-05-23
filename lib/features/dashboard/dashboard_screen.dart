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

  // Sunburst chart specific state variables
  List<Map<String, dynamic>>? _sunburstData;
  double? _sunburstTotalExpenses;
  bool _isSunburstLoading = false;
  String? _sunburstErrorMessage;

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  @override
  void initState() {
    super.initState();
    _fetchSankeyData();
    _fetchSunburstData(); // Call to fetch sunburst data
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

  Future<void> _fetchSunburstData() async {
    setState(() {
      _isSunburstLoading = true;
      _sunburstErrorMessage = null;
    });

    try {
      final HttpsCallable callable = _functions.httpsCallable('getSunburstData');
      final HttpsCallableResult result = await callable.call(<String, dynamic>{
        'period': _selectedPeriod,
        'dateOffset': _dateOffset,
      });

      if (result.data != null) {
        final Map<String, dynamic> responseData = result.data as Map<String, dynamic>;
        // Adapt to the new structure where 'sunburstData' is the root node
        final Map<String, dynamic>? sunburstChartDataRoot = responseData['sunburstData'] as Map<String, dynamic>?;

        if (sunburstChartDataRoot != null && sunburstChartDataRoot['children'] != null) {
          final List<dynamic> childrenData = sunburstChartDataRoot['children'] as List<dynamic>;
          setState(() {
            _sunburstData = childrenData.map((item) => item as Map<String, dynamic>).toList();
            // Calculate total expenses from the sum of children's values
            _sunburstTotalExpenses = childrenData.fold(0.0, (sum, item) {
              final num value = item['value'] as num? ?? 0.0;
              return sum + value.toDouble();
            });
            // If the root node itself has a 'value' (e.g. "Total Expenses"), we could use that too.
            // For now, summing children is robust.
          });
        } else {
          // Handle cases where 'sunburstData' or its 'children' are missing
          setState(() {
            _sunburstData = null;
            _sunburstTotalExpenses = null;
          });
        }
      } else {
        setState(() {
          _sunburstData = null;
          _sunburstTotalExpenses = null;
        });
      }
    } on FirebaseFunctionsException catch (e) {
      setState(() {
        _sunburstErrorMessage = e.message ?? "An unknown error occurred while fetching Sunburst data.";
        _sunburstData = null;
        _sunburstTotalExpenses = null;
      });
    } catch (e) {
      setState(() {
        _sunburstErrorMessage = "An unexpected error occurred: $e";
        _sunburstData = null;
        _sunburstTotalExpenses = null;
      });
    } finally {
      setState(() {
        _isSunburstLoading = false;
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
                      _fetchSunburstData(); // Also fetch sunburst data
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
                if (_isSunburstLoading)
                  const Center(child: CircularProgressIndicator())
                else if (_sunburstErrorMessage != null)
                  Center(child: Text('Sunburst Error: $_sunburstErrorMessage'))
                else if (_sunburstData != null && _sunburstData!.isNotEmpty)
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
                              text: 'Spending Breakdown ${(_sunburstTotalExpenses != null && _sunburstTotalExpenses! > 0) ? "\nTotal: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(_sunburstTotalExpenses)}" : ""}',
                              textStyle: Theme.of(context).textTheme.titleMedium,
                              alignment: ChartAlignment.center
                          ),
                          legend: Legend(isVisible: true, overflowMode: LegendItemOverflowMode.wrap),
                          series: <CircularSeries<Map<String, dynamic>, String>>[
                            DoughnutSeries<Map<String, dynamic>, String>(
                              dataSource: _sunburstData,
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
                                  if (_sunburstTotalExpenses != null && _sunburstTotalExpenses! > 0 && value > 0) {
                                    final double percentage = (value / _sunburstTotalExpenses!) * 100;
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
