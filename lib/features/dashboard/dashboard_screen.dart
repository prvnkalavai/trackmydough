import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
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
                            child: SfSankey(
                              title: SankeyTitle(text: 'Financial Flow Analysis'),
                              links: _sankeyLinksData.map((linkData) => SankeyLink(
                                source: linkData['from']!,
                                target: linkData['to']!,
                                value: (linkData['value'] as num).toDouble(),
                              )).toList(),
                              nodeStyle: SankeyNodeStyle(
                                color: Colors.teal.withOpacity(0.7),
                                borderColor: Colors.black54,
                                borderWidth: 0.5,
                                labelStyle: const TextStyle(fontSize: 11, color: Colors.black87, fontWeight: FontWeight.w500),
                              ),
                              linkStyle: SankeyLinkStyle(
                                colorMode: SankeyLinkColorMode.target, // Color links based on target node
                                color: Colors.blueGrey.withOpacity(0.4), // Default, might be overridden by colorMode
                                // activeColor: Colors.deepPurpleAccent, // Color on interaction
                              ),
                              dataLabelSettings: SankeyDataLabelSettings(
                                isVisible: true,
                                labelPosition: SankeyLabelPosition.center, // Adjust as needed
                                textStyle: const TextStyle(fontSize: 9, color: Colors.black),
                                builder: (BuildContext context, SankeyLinkDetails details, SankeyDataLabelRenderDetails renderDetails) {
                                  final value = renderDetails.value;
                                  final formattedValue = NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(value);
                                  return Text(formattedValue, style: const TextStyle(fontSize: 9, color: Colors.black));
                                }
                              ),
                              tooltipSettings: SankeyTooltipSettings(
                                enable: true,
                                textStyle: const TextStyle(fontSize: 10),
                              ),
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
                      Text(
                        'Spending Breakdown ${(_sunburstTotalExpenses != null && _sunburstTotalExpenses! > 0) ? "- Total: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(_sunburstTotalExpenses)} " : ""}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 350, // Increased height for better visualization
                        child: SfSunburstChart(
                          dataSource: _sunburstData!,
                          xValueMapper: (dynamic data, _) => data['name'] as String,
                          yValueMapper: (dynamic data, _) => data['value'] as num,
                          childItemsPath: 'children',
                          palette: const <Color>[ // Added color palette
                            Colors.blue, Colors.green, Colors.orange, Colors.red, Colors.purple,
                            Colors.brown, Colors.pink, Colors.teal, Colors.indigo, Colors.cyan,
                            Colors.lime, Colors.amber,
                          ],
                          radius: '95%', // Overall radius
                          innerRadius: '30%', // Creates a donut hole
                          dataLabelSettings: SunburstDataLabelSettings(
                            isVisible: true,
                            labelPosition: SunburstLabelPosition.circular,
                            labelRotationMode: SunburstLabelRotationMode.angle,
                            labelFormatter: (SunburstArgs args) {
                              final String name = args.text ?? (args.dataPoint?['name'] as String? ?? '');
                              if (_sunburstTotalExpenses != null && _sunburstTotalExpenses! > 0 && args.value != null) {
                                final double percentage = (args.value! / _sunburstTotalExpenses!) * 100;
                                if (percentage < 2) return ''; // Hide label for very small segments
                                return '${name}\n(${percentage.toStringAsFixed(1)}%)';
                              }
                              return name;
                            },
                            textStyle: const TextStyle(fontSize: 9, color: Colors.black87, fontWeight: FontWeight.w500),
                          ),
                          tooltipSettings: SunburstTooltipSettings(
                            enable: true,
                            tooltipFormatter: (SunburstArgs args) {
                              final String name = args.text ?? (args.dataPoint?['name'] as String? ?? '');
                              final double value = args.value ?? 0;
                              if (_sunburstTotalExpenses != null && _sunburstTotalExpenses! > 0) {
                                final double percentage = (value / _sunburstTotalExpenses!) * 100;
                                return '$name: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(value)} (${percentage.toStringAsFixed(1)}%)';
                              }
                              return '$name: ${NumberFormat.compactCurrency(locale: 'en_US', symbol: '\$').format(value)}';
                            }
                          ),
                          selectionSettings: SunburstSelectionSettings( // Added selection settings
                            enable: true,
                            mode: SunburstSelectionMode.point, // PointSelectionMode is for SfCartesianChart, Sunburst uses SunburstSelectionMode
                            selectedColor: Colors.orangeAccent.shade700,
                            selectedOpacity: 0.9,
                            unselectedOpacity: 0.5,
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  const Center(child: Text('No spending data for Sunburst chart for the selected period.')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
